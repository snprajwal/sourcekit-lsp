//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_spi(SourceKitLSP) import LanguageServerProtocol
import SKTestSupport
import SemanticIndex
import SourceKitLSP
import XCTest

final class DocCSymbolLinkDiagnosticsTests: XCTestCase {
  func testUnresolvedSymbolLinkInDocCommentIsCombinedWithSwiftDiagnostics() async throws {
    let project = try await IndexedSingleSwiftFileTestProject(
      """
      public struct Foo {}

      /// See ``Foo`` and 1️⃣``Missing``2️⃣.
      public func useFoo() {
        bar()
      }
      """,
      allowBuildFailure: true
    )

    let report = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(project.fileURI))
    )
    let items = try XCTUnwrap(report.fullReport?.items)
    XCTAssert(items.contains { $0.message == "Cannot find 'bar' in scope" }, "\(items)")
    XCTAssertEqual(
      items.filter { $0.source == "DocC" },
      [
        Diagnostic(
          range: project.positions["1️⃣"]..<project.positions["2️⃣"],
          severity: .warning,
          source: "DocC",
          message: "No symbol link resolved for 'Missing'"
        )
      ]
    )
  }

  func testDiagnosticsOfClosedDocumentAreEmpty() async throws {
    let project = try await SwiftPMTestProject(
      files: [
        "MyLibrary/MyFile.swift": "",
        "MyLibrary/MyLibrary.docc/Overview.md": """
        # Overview

        See ``Missing``.
        """,
      ]
    )
    let (uri, _) = try project.openDocument("Overview.md")
    let languageService = try await unwrap(project.testClient.primaryLanguageService(for: uri))
    project.testClient.send(DidCloseTextDocumentNotification(textDocument: TextDocumentIdentifier(uri)))
    try await project.testClient.send(SynchronizeRequest())

    // Simulate a diagnostics request that was still in flight when the document was closed.
    let report = try await languageService.documentDiagnostic(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(report.fullReport?.items, [])
  }

  func testUnresolvedSymbolLinkIsNotPulledWhileIndexing() async throws {
    let indexingAllowed = MultiEntrySemaphore(name: "Indexing allowed")
    let project = try await SwiftPMTestProject(
      files: [
        "Test.swift": """
        /// See 1️⃣``Missing``2️⃣.
        public func test() {}
        """
      ],
      hooks: Hooks(
        indexHooks: IndexHooks(updateIndexStoreTaskDidStart: { _ in
          await indexingAllowed.waitOrXCTFail()
        })
      ),
      enableBackgroundIndexing: true,
      pollIndex: false
    )
    let (uri, positions) = try project.openDocument("Test.swift")

    let reportWhileIndexing = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(reportWhileIndexing.fullReport?.items, [])

    indexingAllowed.signal()
    try await project.testClient.send(SynchronizeRequest(index: true))

    let reportAfterIndexing = try await project.testClient.send(
      DocumentDiagnosticsRequest(textDocument: TextDocumentIdentifier(uri))
    )
    XCTAssertEqual(
      reportAfterIndexing.fullReport?.items,
      [
        Diagnostic(
          range: positions["1️⃣"]..<positions["2️⃣"],
          severity: .warning,
          source: "DocC",
          message: "No symbol link resolved for 'Missing'"
        )
      ]
    )
  }

  func testUnresolvedSymbolLinkInMarkdownIsPublishedOnceIndexIsUpToDate() async throws {
    let indexingAllowed = MultiEntrySemaphore(name: "Indexing allowed")
    let project = try await SwiftPMTestProject(
      files: [
        "MyLibrary/MyFile.swift": """
        public struct Foo {}
        """,
        "MyLibrary/MyLibrary.docc/Overview.md": """
        # Overview

        See ``Foo`` and 1️⃣``Missing``2️⃣.
        """,
      ],
      hooks: Hooks(
        indexHooks: IndexHooks(updateIndexStoreTaskDidStart: { _ in
          await indexingAllowed.waitOrXCTFail()
        })
      ),
      enableBackgroundIndexing: true,
      usePullDiagnostics: false,
      pollIndex: false
    )
    let (uri, positions) = try project.openDocument("Overview.md")
    indexingAllowed.signal()

    let notification = try await project.testClient.nextDiagnosticsNotification()
    XCTAssertEqual(notification.uri, uri)
    XCTAssertEqual(
      notification.diagnostics,
      [
        Diagnostic(
          range: positions["1️⃣"]..<positions["2️⃣"],
          severity: .warning,
          source: "DocC",
          message: "No symbol link resolved for 'Missing'"
        )
      ]
    )
  }
}
