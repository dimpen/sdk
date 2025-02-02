// Copyright (c) 2015, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart' as file_system;
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/constant/potentially_constant.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/error/lint_codes.dart';
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisErrorInfo, AnalysisErrorInfoImpl, AnalysisOptions;
import 'package:analyzer/src/generated/resolver.dart'
    show ConstantVerifier, TypeProvider;
import 'package:analyzer/src/generated/source.dart' show LineInfo;
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/lint/analysis.dart';
import 'package:analyzer/src/lint/config.dart';
import 'package:analyzer/src/lint/io.dart';
import 'package:analyzer/src/lint/linter_visitor.dart' show NodeLintRegistry;
import 'package:analyzer/src/lint/project.dart';
import 'package:analyzer/src/lint/pub.dart';
import 'package:analyzer/src/lint/registry.dart';
import 'package:analyzer/src/services/lint.dart' show Linter;
import 'package:analyzer/src/workspace/workspace.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

export 'package:analyzer/src/lint/linter_visitor.dart' show NodeLintRegistry;

typedef Printer(String msg);

/// Describes a String in valid camel case format.
@deprecated // Never intended for public use.
class CamelCaseString {
  static final _camelCaseMatcher = new RegExp(r'[A-Z][a-z]*');
  static final _camelCaseTester = new RegExp(r'^([_$]*)([A-Z?$]+[a-z0-9]*)+$');

  final String value;

  CamelCaseString(this.value) {
    if (!isCamelCase(value)) {
      throw new ArgumentError('$value is not CamelCase');
    }
  }

  String get humanized => _humanize(value);

  @override
  String toString() => value;

  static bool isCamelCase(String name) => _camelCaseTester.hasMatch(name);

  static String _humanize(String camelCase) =>
      _camelCaseMatcher.allMatches(camelCase).map((m) => m.group(0)).join(' ');
}

/// Dart source linter.
class DartLinter implements AnalysisErrorListener {
  final errors = <AnalysisError>[];

  final LinterOptions options;
  final Reporter reporter;

  /// The total number of sources that were analyzed.  Only valid after
  /// [lintFiles] has been called.
  int numSourcesAnalyzed;

  /// Creates a new linter.
  DartLinter(this.options, {this.reporter: const PrintingReporter()});

  Future<Iterable<AnalysisErrorInfo>> lintFiles(List<File> files) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    List<AnalysisErrorInfo> errors = [];
    final lintDriver = new LintDriver(options);
    errors.addAll(await lintDriver.analyze(files.where((f) => isDartFile(f))));
    numSourcesAnalyzed = lintDriver.numSourcesAnalyzed;
    files.where((f) => isPubspecFile(f)).forEach((p) {
      numSourcesAnalyzed++;
      return errors.addAll(_lintPubspecFile(p));
    });
    return errors;
  }

  Iterable<AnalysisErrorInfo> lintPubspecSource(
      {String contents, String sourcePath}) {
    var results = <AnalysisErrorInfo>[];

    Uri sourceUrl = sourcePath == null ? null : p.toUri(sourcePath);

    var spec = new Pubspec.parse(contents, sourceUrl: sourceUrl);

    for (Linter lint in options.enabledLints) {
      if (lint is LintRule) {
        LintRule rule = lint;
        var visitor = rule.getPubspecVisitor();
        if (visitor != null) {
          // Analyzer sets reporters; if this file is not being analyzed,
          // we need to set one ourselves.  (Needless to say, when pubspec
          // processing gets pushed down, this hack can go away.)
          if (rule.reporter == null && sourceUrl != null) {
            var source = createSource(sourceUrl);
            rule.reporter = new ErrorReporter(this, source);
          }
          try {
            spec.accept(visitor);
          } on Exception catch (e) {
            reporter.exception(new LinterException(e.toString()));
          }
          if (rule._locationInfo != null && rule._locationInfo.isNotEmpty) {
            results.addAll(rule._locationInfo);
            rule._locationInfo.clear();
          }
        }
      }
    }

    return results;
  }

  @override
  onError(AnalysisError error) => errors.add(error);

  Iterable<AnalysisErrorInfo> _lintPubspecFile(File sourceFile) =>
      lintPubspecSource(
          contents: sourceFile.readAsStringSync(),
          sourcePath: options.resourceProvider.pathContext
              .normalize(sourceFile.absolute.path));
}

class FileGlobFilter extends LintFilter {
  Iterable<Glob> includes;
  Iterable<Glob> excludes;

  FileGlobFilter([Iterable<String> includeGlobs, Iterable<String> excludeGlobs])
      : includes = includeGlobs.map((glob) => new Glob(glob)),
        excludes = excludeGlobs.map((glob) => new Glob(glob));

  @override
  bool filter(AnalysisError lint) {
    // TODO specify order
    return excludes.any((glob) => glob.matches(lint.source.fullName)) &&
        !includes.any((glob) => glob.matches(lint.source.fullName));
  }
}

class Group implements Comparable<Group> {
  /// Defined rule groups.
  static const Group errors =
      const Group._('errors', description: 'Possible coding errors.');
  static const Group pub = const Group._('pub',
      description: 'Pub-related rules.',
      link: const Hyperlink('See the <strong>Pubspec Format</strong>',
          'https://www.dartlang.org/tools/pub/pubspec.html'));
  static const Group style = const Group._('style',
      description:
          'Matters of style, largely derived from the official Dart Style Guide.',
      link: const Hyperlink('See the <strong>Style Guide</strong>',
          'https://www.dartlang.org/articles/style-guide/'));

  /// List of builtin groups in presentation order.
  static const Iterable<Group> builtin = const [errors, style, pub];

  final String name;
  final bool custom;
  final String description;
  final Hyperlink link;

  factory Group(String name, {String description: '', Hyperlink link}) {
    var n = name.toLowerCase();
    return builtin.firstWhere((g) => g.name == n,
        orElse: () => new Group._(name,
            custom: true, description: description, link: link));
  }

  const Group._(this.name, {this.custom: false, this.description, this.link});

  @override
  int compareTo(Group other) => name.compareTo(other.name);
}

class Hyperlink {
  final String label;
  final String href;
  final bool bold;

  const Hyperlink(this.label, this.href, {this.bold: false});

  String get html => '<a href="$href">${_emph(label)}</a>';

  String _emph(msg) => bold ? '<strong>$msg</strong>' : msg;
}

/// Provides access to information needed by lint rules that is not available
/// from AST nodes or the element model.
abstract class LinterContext {
  List<LinterContextUnit> get allUnits;

  AnalysisOptions get analysisOptions;

  LinterContextUnit get currentUnit;

  DeclaredVariables get declaredVariables;

  InheritanceManager3 get inheritanceManager;

  WorkspacePackage get package;

  TypeProvider get typeProvider;

  TypeSystem get typeSystem;

  /// Return `true` if it would be valid for the given instance creation
  /// [expression] to have a keyword of `const`.
  ///
  /// The [expression] is expected to be a node within one of the compilation
  /// units in [allUnits].
  ///
  /// Note that this method can cause constant evaluation to occur, which can be
  /// computationally expensive.
  bool canBeConst(InstanceCreationExpression expression);

  /// Return `true` if it would be valid for the given constructor declaration
  /// [node] to have a keyword of `const`.
  ///
  /// The [node] is expected to be a node within one of the compilation
  /// units in [allUnits].
  ///
  /// Note that this method can cause constant evaluation to occur, which can be
  /// computationally expensive.
  bool canBeConstConstructor(ConstructorDeclaration node);
}

/// Implementation of [LinterContext]
class LinterContextImpl implements LinterContext {
  @override
  final List<LinterContextUnit> allUnits;

  @override
  final AnalysisOptions analysisOptions;

  @override
  final LinterContextUnit currentUnit;

  @override
  final DeclaredVariables declaredVariables;

  @override
  final WorkspacePackage package;

  @override
  final TypeProvider typeProvider;

  @override
  final TypeSystem typeSystem;

  @override
  final InheritanceManager3 inheritanceManager;

  LinterContextImpl(
    this.allUnits,
    this.currentUnit,
    this.declaredVariables,
    this.typeProvider,
    this.typeSystem,
    this.inheritanceManager,
    this.analysisOptions,
    this.package,
  );

  @override
  bool canBeConst(InstanceCreationExpression expression) {
    //
    // Verify that the invoked constructor is a const constructor.
    //
    ConstructorElement element = expression.staticElement;
    if (element == null || !element.isConst) {
      return false;
    }

    // Ensure that dependencies (e.g. default parameter values) are computed.
    ConstructorElementImpl implElement = element.declaration;
    implElement.computeConstantDependencies();

    //
    // Verify that the evaluation of the constructor would not produce an
    // exception.
    //
    Token oldKeyword = expression.keyword;
    try {
      expression.keyword = new KeywordToken(Keyword.CONST, expression.offset);
      return !_hasConstantVerifierError(expression);
    } finally {
      expression.keyword = oldKeyword;
    }
  }

  @override
  bool canBeConstConstructor(ConstructorDeclaration node) {
    ConstructorElement element = node.declaredElement;

    ClassElement classElement = element.enclosingElement;
    if (classElement.hasNonFinalField) return false;

    var oldKeyword = node.constKeyword;
    try {
      temporaryConstConstructorElements[element] = true;
      node.constKeyword = KeywordToken(Keyword.CONST, node.offset);
      return !_hasConstantVerifierError(node);
    } finally {
      temporaryConstConstructorElements[element] = null;
      node.constKeyword = oldKeyword;
    }
  }

  /// Return `true` if [ConstantVerifier] reports an error for the [node].
  bool _hasConstantVerifierError(AstNode node) {
    var unitElement = currentUnit.unit.declaredElement;
    var libraryElement = unitElement.library;

    var listener = ConstantAnalysisErrorListener();
    var errorReporter = ErrorReporter(listener, unitElement.source);

    node.accept(
      ConstantVerifier(
        errorReporter,
        libraryElement,
        typeProvider,
        declaredVariables,
        featureSet: currentUnit.unit.featureSet,
      ),
    );
    return listener.hasConstError;
  }
}

class LinterContextUnit {
  final String content;

  final CompilationUnit unit;

  LinterContextUnit(this.content, this.unit);
}

/// Thrown when an error occurs in linting.
class LinterException implements Exception {
  /// A message describing the error.
  final String message;

  /// Creates a new LinterException with an optional error [message].
  const LinterException([this.message]);

  @override
  String toString() =>
      message == null ? "LinterException" : "LinterException: $message";
}

/// Linter options.
class LinterOptions extends DriverOptions {
  Iterable<LintRule> enabledLints;
  String analysisOptions;
  LintFilter filter;
  file_system.ResourceProvider resourceProvider;

  // todo (pq): consider migrating to named params (but note Linter dep).
  LinterOptions([this.enabledLints, this.analysisOptions]) {
    enabledLints ??= Registry.ruleRegistry;
  }

  void configure(LintConfig config) {
    enabledLints = Registry.ruleRegistry.where((LintRule rule) =>
        !config.ruleConfigs.any((rc) => rc.disables(rule.name)));
    filter = new FileGlobFilter(config.fileIncludes, config.fileExcludes);
  }
}

/// Filtered lints are omitted from linter output.
abstract class LintFilter {
  bool filter(AnalysisError lint);
}

/// Describes a lint rule.
abstract class LintRule extends Linter implements Comparable<LintRule> {
  /// Description (in markdown format) suitable for display in a detailed lint
  /// description.
  final String details;

  /// Short description suitable for display in console output.
  final String description;

  /// Lint group (for example, 'style').
  final Group group;

  /// Lint maturity (stable|experimental).
  final Maturity maturity;

  /// Lint name.
  @override
  final String name;

  /// Until pubspec analysis is pushed into the analyzer proper, we need to
  /// do some extra book-keeping to keep track of details that will help us
  /// constitute AnalysisErrorInfos.
  final List<AnalysisErrorInfo> _locationInfo = <AnalysisErrorInfo>[];

  LintRule(
      {this.name,
      this.group,
      this.description,
      this.details,
      this.maturity: Maturity.stable});

  LintCode get lintCode => new _LintCode(name, description);

  @override
  int compareTo(LintRule other) {
    var g = group.compareTo(other.group);
    if (g != 0) {
      return g;
    }
    return name.compareTo(other.name);
  }

  /// Return a visitor to be passed to provide access to Dart project context
  /// and to perform project-level analyses.
  ProjectVisitor getProjectVisitor() => null;

  /// Return a visitor to be passed to pubspecs to perform lint
  /// analysis.
  /// Lint errors are reported via this [Linter]'s error [reporter].
  PubspecVisitor getPubspecVisitor() => null;

  @override
  AstVisitor getVisitor() => null;

  void reportLint(AstNode node,
      {List<Object> arguments: const [],
      ErrorCode errorCode,
      bool ignoreSyntheticNodes: true}) {
    if (node != null && (!node.isSynthetic || !ignoreSyntheticNodes)) {
      reporter.reportErrorForNode(errorCode ?? lintCode, node, arguments);
    }
  }

  void reportLintForToken(Token token,
      {List<Object> arguments: const [],
      ErrorCode errorCode,
      bool ignoreSyntheticTokens: true}) {
    if (token != null && (!token.isSynthetic || !ignoreSyntheticTokens)) {
      reporter.reportErrorForToken(errorCode ?? lintCode, token, arguments);
    }
  }

  void reportPubLint(PSNode node) {
    Source source = createSource(node.span.sourceUrl);

    // Cache error and location info for creating AnalysisErrorInfos
    AnalysisError error = new AnalysisError(
        source, node.span.start.offset, node.span.length, lintCode);
    LineInfo lineInfo = new LineInfo.fromContent(source.contents.data);

    _locationInfo.add(new AnalysisErrorInfoImpl([error], lineInfo));

    // Then do the reporting
    reporter?.reportError(error);
  }
}

class Maturity implements Comparable<Maturity> {
  static const Maturity stable = const Maturity._('stable', ordinal: 0);
  static const Maturity experimental =
      const Maturity._('experimental', ordinal: 1);
  static const Maturity deprecated = const Maturity._('deprecated', ordinal: 2);

  final String name;
  final int ordinal;

  factory Maturity(String name, {int ordinal}) {
    switch (name.toLowerCase()) {
      case 'stable':
        return stable;
      case 'experimental':
        return experimental;
      case 'deprecated':
        return deprecated;
      default:
        return new Maturity._(name, ordinal: ordinal);
    }
  }

  const Maturity._(this.name, {this.ordinal});

  @override
  int compareTo(Maturity other) => this.ordinal - other.ordinal;
}

/// [LintRule]s that implement this interface want to process only some types
/// of AST nodes, and will register their processors in the registry.
abstract class NodeLintRule {
  /// This method is invoked to let the [LintRule] register node processors
  /// in the given [registry].
  ///
  /// The node processors may use the provided [context] to access information
  /// that is not available from the AST nodes or their associated elements.
  void registerNodeProcessors(NodeLintRegistry registry, LinterContext context);
}

/// [LintRule]s that implement this interface want to process only some types
/// of AST nodes, and will register their processors in the registry.
///
/// This class exists solely to allow a smoother transition from analyzer
/// version 0.33.*.  It will be removed in a future analyzer release, so please
/// use [NodeLintRule] instead.
@deprecated
abstract class NodeLintRuleWithContext extends NodeLintRule {}

class PrintingReporter implements Reporter {
  final Printer _print;

  const PrintingReporter([this._print = print]);

  @override
  void exception(LinterException exception) {
    _print('EXCEPTION: $exception');
  }

  @override
  void warn(String message) {
    _print('WARN: $message');
  }
}

abstract class Reporter {
  void exception(LinterException exception);

  void warn(String message);
}

/// Linter implementation.
class SourceLinter implements DartLinter, AnalysisErrorListener {
  @override
  final errors = <AnalysisError>[];
  @override
  final LinterOptions options;
  @override
  final Reporter reporter;

  @override
  int numSourcesAnalyzed;

  SourceLinter(this.options, {this.reporter: const PrintingReporter()});

  @override
  Future<Iterable<AnalysisErrorInfo>> lintFiles(List<File> files) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    List<AnalysisErrorInfo> errors = [];
    final lintDriver = new LintDriver(options);
    errors.addAll(await lintDriver.analyze(files.where((f) => isDartFile(f))));
    numSourcesAnalyzed = lintDriver.numSourcesAnalyzed;
    files.where((f) => isPubspecFile(f)).forEach((p) {
      numSourcesAnalyzed++;
      return errors.addAll(_lintPubspecFile(p));
    });
    return errors;
  }

  @override
  Iterable<AnalysisErrorInfo> lintPubspecSource(
      {String contents, String sourcePath}) {
    var results = <AnalysisErrorInfo>[];

    Uri sourceUrl = sourcePath == null ? null : p.toUri(sourcePath);

    var spec = new Pubspec.parse(contents, sourceUrl: sourceUrl);

    for (Linter lint in options.enabledLints) {
      if (lint is LintRule) {
        LintRule rule = lint;
        var visitor = rule.getPubspecVisitor();
        if (visitor != null) {
          // Analyzer sets reporters; if this file is not being analyzed,
          // we need to set one ourselves.  (Needless to say, when pubspec
          // processing gets pushed down, this hack can go away.)
          if (rule.reporter == null && sourceUrl != null) {
            var source = createSource(sourceUrl);
            rule.reporter = new ErrorReporter(this, source);
          }
          try {
            spec.accept(visitor);
          } on Exception catch (e) {
            reporter.exception(new LinterException(e.toString()));
          }
          if (rule._locationInfo != null && rule._locationInfo.isNotEmpty) {
            results.addAll(rule._locationInfo);
            rule._locationInfo.clear();
          }
        }
      }
    }

    return results;
  }

  @override
  onError(AnalysisError error) => errors.add(error);

  @override
  Iterable<AnalysisErrorInfo> _lintPubspecFile(File sourceFile) =>
      lintPubspecSource(
          contents: sourceFile.readAsStringSync(), sourcePath: sourceFile.path);
}

class _LintCode extends LintCode {
  static final registry = <String, LintCode>{};

  factory _LintCode(String name, String message) => registry.putIfAbsent(
      name + message, () => new _LintCode._(name, message));

  _LintCode._(String name, String message) : super(name, message);
}
