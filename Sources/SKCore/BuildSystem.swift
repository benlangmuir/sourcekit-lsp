//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import Basic

/// Provider of FileBuildSettings and other build-related information.
///
/// The primary role of the build system is to answer queries for FileBuildSettings and (TODO) to
/// notify clients when they change. The BuildSystem is also the source of related informatino,
/// such as where the index datastore is located.
///
/// For example, a SwiftPMWorkspace provides compiler arguments for the files contained in a
/// SwiftPM package root directory.
public protocol BuildSystem {

  /// The path to the raw index store data, if any.
  var indexStorePath: AbsolutePath? { get }

  /// The path to put the index database, if any.
  var indexDatabasePath: AbsolutePath? { get }

  /// Provides the settings for the given url and language mode via callback.
  ///
  /// - parameters:
  ///   - url: The document whose settings to retrieve.
  ///   - language: The language (swift, c++, etc.) of the file.
  ///   - completion: Called asynchronously with the appropriate FileBuildSettings, or nil.
  func settings(
    for url: URL, 
    _ language: Language, 
    _ completion: @escaping (URL, Language, FileBuildSettings?) -> Void)

  // TODO: notifications when settings change.
}
