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

import Basic
import LanguageServerProtocol
import Dispatch

/// A `BuildSystem` based on loading clang-compatible compilation database(s).
///
/// Provides build settings from a `CompilationDatabase` found by searching a project. For now, only
/// one compilation database, located at the project root.
public final class CompilationDatabaseBuildSystem {

  /// The compilation database.
  var compdb: CompilationDatabase? = nil

  /// The FileSystem to use for reading compilation database files.
  let fileSystem: FileSystem

  /// DispatchQueue used to execute queries asynchronously.
  let queue: DispatchQueue =
    DispatchQueue(label: "\(CompilationDatabaseBuildSystem.self)", qos: .utility)

  public init(projectRoot: AbsolutePath? = nil, fileSystem: FileSystem = localFileSystem) {
    self.fileSystem = fileSystem
    if let path = projectRoot {
      self.compdb = tryLoadCompilationDatabase(directory: path, fileSystem: fileSystem)
    }
  }
}

extension CompilationDatabaseBuildSystem: BuildSystem {

  // FIXME: derive from the compiler arguments.
  public var indexStorePath: AbsolutePath? { return nil }
  public var indexDatabasePath: AbsolutePath? { return nil }

  public func settings(
    for url: URL, 
    _ language: Language, 
    _ completion: @escaping (URL, Language, FileBuildSettings?) -> Void)
  {
    queue.async {
      var settings: FileBuildSettings? = nil
      if let db = self.database(for: url), let cmd = db[url].first { 
        settings = FileBuildSettings(
          preferredToolchain: nil, // FIXME: infer from path
          compilerArguments: Array(cmd.commandLine.dropFirst()),
          workingDirectory: cmd.directory)
      }
      completion(url, language, settings)
    }
  }

  func database(for url: URL) -> CompilationDatabase? {
    if let path = try? AbsolutePath(validating: url.path) {
      return database(for: path)
    }
    return compdb
  }

  func database(for path: AbsolutePath) -> CompilationDatabase? {
    if compdb == nil {
      var dir = path
      while !dir.isRoot {
        dir = dir.parentDirectory
        if let db = tryLoadCompilationDatabase(directory: dir, fileSystem: fileSystem) {
          compdb = db
          break
        }
      }
    }
    return compdb
  }
}
