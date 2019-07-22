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
