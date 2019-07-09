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

@testable import SourceKit
import LanguageServerProtocol
import Basic
import SPMUtility
import SKCore
import SKTestSupport
import IndexStoreDB
import ISDBTestSupport
import XCTest

public typealias URL = Foundation.URL

final class SKTests: XCTestCase {

    func testInitLocal() {
      let c = TestSourceKitServer()

      let sk = c.client

      let initResult = try! sk.sendSync(InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURL: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
        trace: .off,
        workspaceFolders: nil))

      XCTAssertEqual(initResult.capabilities.textDocumentSync?.openClose, true)
      XCTAssertNotNil(initResult.capabilities.completionProvider)
    }

    func testInitJSON() {
      let c = TestSourceKitServer(connectionKind: .jsonrpc)

      let sk = c.client

      let initResult = try! sk.sendSync(InitializeRequest(
        processId: nil,
        rootPath: nil,
        rootURL: nil,
        initializationOptions: nil,
        capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
        trace: .off,
        workspaceFolders: nil))

      XCTAssertEqual(initResult.capabilities.textDocumentSync?.openClose, true)
      XCTAssertNotNil(initResult.capabilities.completionProvider)
    }

  func testIndex() throws {
    let ws = try skTibsWorkspace(name: "proj1")
    try ws.buildAndIndex()

    let curl = ws.testLoc("c:call").url
    ws.sk.send(DidOpenTextDocument(textDocument: TextDocumentItem(
      url: curl,
      language: .swift,
      version: 1,
      text: try ws.sources.sourceCache.get(curl))))

    let result = try ws.sk.sendSync(ReferencesRequest(
      textDocument: TextDocumentIdentifier(curl), position: Position(line: ws.testLoc("c:call").line - 1, utf16index: ws.testLoc("c:call").column - 1)))
    // FIXME: utf8 vs utf16 column

    XCTAssertEqual(2, result.count)

  }
}

public final class SKTibsWorkspace {

  public static let defaultToolchain = TibsToolchain(
    swiftc: findTool(name: "swiftc")!,
    ninja: findTool(name: "ninja"))

  public var sources: TestSources
  public var builder: TibsBuilder
  public let index: IndexStoreDB
  public let testServer = TestSourceKitServer(connectionKind: .jsonrpc)
  public let tmpDir: URL

  public init(projectDir: URL, buildDir: URL, tmpDir: URL, toolchain: TibsToolchain = SKTibsWorkspace.defaultToolchain) throws {
    sources = try TestSources(rootDirectory: projectDir)

    let fm = FileManager.default
    try fm.createDirectory(at: buildDir, withIntermediateDirectories: true, attributes: nil)

    let manifestURL = projectDir.appendingPathComponent("project.json")
    let manifest = try JSONDecoder().decode(TibsManifest.self, from: try Data(contentsOf: manifestURL))
    builder = try TibsBuilder(manifest: manifest, sourceRoot: projectDir, buildRoot: buildDir, toolchain: toolchain)

    try builder.writeBuildFiles()
    try fm.createDirectory(at: builder.indexstore, withIntermediateDirectories: true, attributes: nil)

    let libIndexStore = try IndexStoreLibrary(dylibPath: toolchain.swiftc
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("lib")
      .appendingPathComponent("libIndexStore.dylib")
      .path) // FIXME: non-Mac

    self.tmpDir = tmpDir

    index = try IndexStoreDB(
      storePath: builder.indexstore.path,
      databasePath: tmpDir.path,
      library: libIndexStore, listenToUnitEvents: false)

    let buildPath = AbsolutePath(buildDir.path)

    testServer.server!.workspace = Workspace(
          rootPath: AbsolutePath(projectDir.path),
          clientCapabilities: ClientCapabilities(),
          buildSettings: CompilationDatabaseBuildSystem(projectRoot: buildPath),
          index: index,
          buildSetup: BuildSetup(configuration: .debug, path: buildPath, flags: BuildFlags()))

    sk.allowUnexpectedNotification = true
  }

  deinit {
    _ = try? FileManager.default.removeItem(atPath: tmpDir.path)
  }
}

extension SKTibsWorkspace {

  public var sk: TestClient { testServer.client }

  public func buildAndIndex() throws {
    try builder.build()
    index.pollForUnitChangesAndWait()
  }
}

extension SKTibsWorkspace {

  public func testLoc(_ name: String) -> TestLoc { sources.locations[name]! }
}

extension XCTestCase {

  public func skTibsWorkspace(name: String, testFile: String = #file) throws -> SKTibsWorkspace {
    let testDirName = testDirectoryName
    return try SKTibsWorkspace(
      projectDir: inputsDirectory(testFile: testFile).appendingPathComponent(name),
      buildDir: productsDirectory
        .appendingPathComponent("sk-tests")
        .appendingPathComponent(testDirName),
      tmpDir: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sk-test-data")
        .appendingPathComponent(testDirName))
  }
}
