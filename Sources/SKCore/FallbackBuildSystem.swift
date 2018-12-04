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
import enum Utility.Platform
import Dispatch

/// A simple BuildSystem suitable as a fallback when accurate settings are unknown.
public final class FallbackBuildSystem {

  /// The path to the SDK.
  lazy var sdkpath: AbsolutePath? = {
    if case .darwin? = Platform.currentPlatform,
       let str = try? Process.checkNonZeroExit(
         args: "/usr/bin/xcrun", "--show-sdk-path", "--sdk", "macosx"),
       let path = try? AbsolutePath(validating: str.spm_chomp())
    {
      return path
    }
    return nil
  }()

  /// DispatchQueue used to execute queries asynchronously.
  let queue: DispatchQueue = DispatchQueue(label: "\(FallbackBuildSystem.self)", qos: .utility)
}

extension FallbackBuildSystem: BuildSystem {
  public var indexStorePath: AbsolutePath? { return nil }
  public var indexDatabasePath: AbsolutePath? { return nil }

  public func settings(
    for url: URL, 
    _ language: Language, 
    _ completion: @escaping (URL, Language, FileBuildSettings?) -> Void)
  {
    queue.async {
      guard let path = try? AbsolutePath(validating: url.path) else {
        completion(url, language, nil)
        return
      }

      switch language {
      case .swift:
        completion(url, language, self.settingsSwift(path))
      case .c, .cpp, .objective_c, .objective_cpp:
        completion(url, language, self.settingsClang(path, language))
      default:
        completion(url, language, nil)
      }
    }
  }

  func settingsSwift(_ path: AbsolutePath) -> FileBuildSettings {
    var args: [String] = []
    if let sdkpath = sdkpath {
      args += [
        "-sdk",
        sdkpath.asString,
      ]
    }
    args.append(path.asString)
    return FileBuildSettings(preferredToolchain: nil, compilerArguments: args)
  }

  func settingsClang(_ path: AbsolutePath, _ language: Language) -> FileBuildSettings {
    var args: [String] = []
    if let sdkpath = sdkpath {
      args += [
        "-isysroot",
        sdkpath.asString,
      ]
    }
    args.append(path.asString)
    return FileBuildSettings(preferredToolchain: nil, compilerArguments: args)
  }
}
