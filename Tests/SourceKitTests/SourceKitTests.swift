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
import ISDBTibs
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
    guard let ws = try staticSourceKitTibsWorkspace(name: "SwiftModules") else { return }
    try ws.buildAndIndex()

    let locDef = ws.testLoc("aaa:def")
    let locRef = ws.testLoc("aaa:call:c")

    try ws.openDocument(locDef.url, language: .swift)
    try ws.openDocument(locRef.url, language: .swift)

    // MARK: Jump to definition

    let jump = try ws.sk.sendSync(DefinitionRequest(
      textDocument: locRef.docIdentifier,
      position: locRef.position))

    XCTAssertEqual(jump.count, 1)
    XCTAssertEqual(jump.first?.url, locDef.url)
    XCTAssertEqual(jump.first?.range.lowerBound, locDef.position)

    // MARK: Find references

    let refs = try ws.sk.sendSync(ReferencesRequest(
      textDocument: locDef.docIdentifier,
      position: locDef.position))

    XCTAssertEqual(3, refs.count)
  }
}

extension TestLoc {
  public var position: Position {
    Position(self)
  }
}

extension Position {
  init(_ loc: TestLoc) {
    // FIXME: utf16 vfs utf8 column
    self.init(line: loc.line - 1, utf16index: loc.column - 1)
  }
}

extension XCTestCase {

  public func staticSourceKitTibsWorkspace(name: String, testFile: String = #file) throws -> SKTibsWorkspace? {
    let testDirName = testDirectoryName
    let workspace = try SKTibsWorkspace(
      immutableProjectDir: inputsDirectory(testFile: testFile)
        .appendingPathComponent(name, isDirectory: true),
      persistentBuildDir: XCTestCase.productsDirectory
        .appendingPathComponent("sk-tests/\(testDirName)", isDirectory: true),
      tmpDir: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("sk-test-data/\(testDirName)", isDirectory: true),
      toolchain: ToolchainRegistry.shared.default!)

    if workspace.builder.targets.contains(where: { target in !target.clangTUs.isEmpty })
      && !workspace.builder.toolchain.clangHasIndexSupport {
      fputs("warning: skipping test because '\(workspace.builder.toolchain.clang.path)' does not " +
            "have indexstore support; use swift-clang\n", stderr)
      return nil
    }

    return workspace
  }
}



// MARK: - New -

extension TibsToolchain {
  convenience init(_ sktc: Toolchain) {
    self.init(
      swiftc: sktc.swiftc!.asURL,
      clang: sktc.clang!.asURL,
      libIndexStore: sktc.libIndexStore!.asURL,
      tibs: XCTestCase.productsDirectory.appendingPathComponent("tibs", isDirectory: false),
      ninja: findTool(name: "ninja"))
  }
}

public final class SKTibsWorkspace {

  public let tibsWorkspace: TibsTestWorkspace
  public let testServer = TestSourceKitServer(connectionKind: .local)

  public var index: IndexStoreDB { tibsWorkspace.index }
  public var builder: TibsBuilder { tibsWorkspace.builder }
  public var sources: TestSources { tibsWorkspace.sources }
  public var sk: TestClient { testServer.client }

  public init(
    immutableProjectDir: URL,
    persistentBuildDir: URL,
    tmpDir: URL,
    toolchain: Toolchain) throws
  {
    self.tibsWorkspace = try TibsTestWorkspace(
      immutableProjectDir: immutableProjectDir,
      persistentBuildDir: persistentBuildDir,
      tmpDir: tmpDir,
      toolchain: TibsToolchain(toolchain))

    sk.allowUnexpectedNotification = true
    initWorkspace()
  }

  public init(projectDir: URL, tmpDir: URL, toolchain: Toolchain) throws {
    self.tibsWorkspace = try TibsTestWorkspace(
      projectDir: projectDir,
      tmpDir: tmpDir,
      toolchain: TibsToolchain(toolchain))

    sk.allowUnexpectedNotification = true
    initWorkspace()
  }

  func initWorkspace() {
    let buildPath = AbsolutePath(builder.buildRoot.path)
    testServer.server!.workspace = Workspace(
      rootPath: AbsolutePath(sources.rootDirectory.path),
      clientCapabilities: ClientCapabilities(),
      buildSettings: CompilationDatabaseBuildSystem(projectRoot: buildPath),
      index: index,
      buildSetup: BuildSetup(configuration: .debug, path: buildPath, flags: BuildFlags()))
  }
}

extension SKTibsWorkspace {

  public func testLoc(_ name: String) -> TestLoc { sources.locations[name]! }

  public func buildAndIndex() throws {
    try tibsWorkspace.buildAndIndex()
  }
}

extension SKTibsWorkspace {
  func openDocument(_ url: URL, language: Language) throws {
    sk.send(DidOpenTextDocument(textDocument: TextDocumentItem(
      url: url,
      language: language,
      version: 1,
      text: try sources.sourceCache.get(url))))
  }
}

extension TestLoc {
  var docIdentifier: TextDocumentIdentifier { TextDocumentIdentifier(url) }
}
