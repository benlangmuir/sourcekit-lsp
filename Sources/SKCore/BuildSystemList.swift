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

/// Provides build settings from a list of build systems in priority order.
public final class BuildSystemList {

  /// The build systems to try (in order).
  public var providers: [BuildSystem] = [
    FallbackBuildSystem()
  ]

  public init() {}
}

extension BuildSystemList: BuildSystem {

  public var indexStorePath: AbsolutePath? { return providers.first?.indexStorePath }

  public var indexDatabasePath: AbsolutePath? { return providers.first?.indexDatabasePath }

  public func settings(
    for url: URL, 
    _ language: Language, 
    _ completion: @escaping (URL, Language, FileBuildSettings?) -> Void)
  {
    precondition(!providers.isEmpty)

    var providers = self.providers[...]
    var continuation: ((URL, Language, FileBuildSettings?) -> Void)? = nil
    continuation = { (url: URL, language: Language, settings: FileBuildSettings?) -> Void in
      if let settings = settings {
        return completion(url, language, settings)
      }
      // Try the next provider.
      if let provider = providers.popFirst() {
        return provider.settings(for: url, language, continuation!)
      }
      // Failed to find any settings.
      completion(url, language, nil)
    }

    // Start the chain. Passing nil triggers looking at the first provider.
    continuation!(url, language, nil)
  }
}
