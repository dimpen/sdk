// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/analysis/uri_converter.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/dart/analysis/driver.dart' as driver;
import 'package:analyzer/src/dart/analysis/uri_converter.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/generated/engine.dart' show AnalysisOptionsImpl;
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/source.dart';

/// A concrete implementation of an analysis session.
class AnalysisSessionImpl implements AnalysisSession {
  /// The analysis driver performing analysis for this session.
  final driver.AnalysisDriver _driver;

  /// The type provider being used by the analysis driver.
  TypeProvider _typeProvider;

  /// The type system being used by the analysis driver.
  TypeSystemImpl _typeSystem;

  /// The URI converter used to convert between URI's and file paths.
  UriConverter _uriConverter;

  /// The cache of libraries for URIs.
  final Map<String, LibraryElement> _uriToLibraryCache = {};

  /// Initialize a newly created analysis session.
  AnalysisSessionImpl(this._driver);

  @override
  AnalysisContext get analysisContext => _driver.analysisContext;

  @override
  DeclaredVariables get declaredVariables => _driver.declaredVariables;

  @override
  ResourceProvider get resourceProvider => _driver.resourceProvider;

  @override
  SourceFactory get sourceFactory => _driver.sourceFactory;

  @override
  Future<TypeProvider> get typeProvider async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    _checkConsistency();
    if (_typeProvider == null) {
      LibraryElement coreLibrary = await _driver.getLibraryByUri('dart:core');
      LibraryElement asyncLibrary = await _driver.getLibraryByUri('dart:async');
      _typeProvider = new TypeProviderImpl(coreLibrary, asyncLibrary);
    }
    return _typeProvider;
  }

  @override
  Future<TypeSystemImpl> get typeSystem async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    _checkConsistency();
    if (_typeSystem == null) {
      _typeSystem = TypeSystemImpl(await typeProvider);
    }
    return _typeSystem;
  }

  @override
  UriConverter get uriConverter {
    return _uriConverter ??= new DriverBasedUriConverter(_driver);
  }

  @deprecated
  driver.AnalysisDriver getDriver() => _driver;

  @override
  Future<ErrorsResult> getErrors(String path) {
    _checkConsistency();
    return _driver.getErrors(path);
  }

  @override
  FileResult getFile(String path) {
    _checkConsistency();
    return _driver.getFileSync(path);
  }

  @override
  Future<LibraryElement> getLibraryByUri(String uri) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    _checkConsistency();
    var libraryElement = _uriToLibraryCache[uri];
    if (libraryElement == null) {
      libraryElement = await _driver.getLibraryByUri(uri);
      _uriToLibraryCache[uri] = libraryElement;
    }
    return libraryElement;
  }

  @deprecated
  @override
  Future<ParseResult> getParsedAst(String path) async => getParsedUnit(path);

  @deprecated
  @override
  ParseResult getParsedAstSync(String path) => getParsedUnit(path);

  @override
  ParsedLibraryResult getParsedLibrary(String path) {
    _checkConsistency();
    return _driver.getParsedLibrary(path);
  }

  @override
  ParsedLibraryResult getParsedLibraryByElement(LibraryElement element) {
    _checkConsistency();
    _checkElementOfThisSession(element);
    return _driver.getParsedLibraryByUri(element.source.uri);
  }

  @override
  ParsedUnitResult getParsedUnit(String path) {
    _checkConsistency();
    return _driver.parseFileSync(path);
  }

  @deprecated
  @override
  Future<ResolveResult> getResolvedAst(String path) => getResolvedUnit(path);

  @override
  Future<ResolvedLibraryResult> getResolvedLibrary(String path) {
    _checkConsistency();
    return _driver.getResolvedLibrary(path);
  }

  @override
  Future<ResolvedLibraryResult> getResolvedLibraryByElement(
      LibraryElement element) {
    _checkConsistency();
    _checkElementOfThisSession(element);
    return _driver.getResolvedLibraryByUri(element.source.uri);
  }

  @override
  Future<ResolvedUnitResult> getResolvedUnit(String path) {
    _checkConsistency();
    return _driver.getResult(path);
  }

  @override
  Future<SourceKind> getSourceKind(String path) {
    _checkConsistency();
    return _driver.getSourceKind(path);
  }

  @override
  Future<UnitElementResult> getUnitElement(String path) {
    _checkConsistency();
    return _driver.getUnitElement(path);
  }

  @override
  Future<String> getUnitElementSignature(String path) {
    _checkConsistency();
    return _driver.getUnitElementSignature(path);
  }

  /// Check to see that results from this session will be consistent, and throw
  /// an [InconsistentAnalysisException] if they might not be.
  void _checkConsistency() {
    if (_driver.currentSession != this) {
      throw new InconsistentAnalysisException();
    }
  }

  void _checkElementOfThisSession(Element element) {
    if (element.session != this) {
      throw new ArgumentError(
          '(${element.runtimeType}) $element was not produced by '
          'this session.');
    }
  }
}

/// Data structure containing information about the analysis session that is
/// available synchronously.
class SynchronousSession {
  final AnalysisOptionsImpl analysisOptions;

  final DeclaredVariables declaredVariables;

  TypeProvider _typeProvider;

  TypeSystemImpl _typeSystem;

  SynchronousSession(this.analysisOptions, this.declaredVariables);

  TypeProvider get typeProvider => _typeProvider;

  set typeProvider(TypeProvider typeProvider) {
    if (_typeProvider != null) {
      throw StateError('TypeProvider can be set only once.');
    }
    _typeProvider = typeProvider;
  }

  TypeSystemImpl get typeSystem {
    return _typeSystem ??= TypeSystemImpl(
      typeProvider,
      implicitCasts: analysisOptions.implicitCasts,
      strictInference: analysisOptions.strictInference,
    );
  }

  void clearTypeProvider() {
    _typeProvider = null;
    _typeSystem = null;
  }
}
