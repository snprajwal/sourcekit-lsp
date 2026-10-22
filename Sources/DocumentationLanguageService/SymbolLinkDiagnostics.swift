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

import BuildServerIntegration
@preconcurrency import IndexStoreDB
@_spi(SourceKitLSP) package import LanguageServerProtocol
import Markdown
@_spi(SourceKitLSP) import SKLogging
import SKOptions
import SemanticIndex
import SourceKitLSP
@_spi(SourceKitLSP) import SwiftSyntax

/// Walks a Markdown document, collecting the destination and range of every symbol link.
private struct SymbolLinkCollector: MarkupWalker {
  var links: [(destination: String, range: Markdown.SourceRange)] = []

  mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
    if let destination = symbolLink.destination, let range = symbolLink.range {
      links.append((destination, range))
    }
  }
}

extension DocumentationLanguageService {
  /// Resolve the given symbol link to the occurrence of the symbol it refers to.
  func resolve(
    _ symbolLink: DocCSymbolLink,
    in workspace: Workspace,
    index: CheckedIndex,
    onDiskDocumentManager: OnDiskDocumentManager
  ) async throws -> SymbolOccurrence? {
    try await index.primaryDefinitionOrDeclarationOccurrence(
      ofDocCSymbolLink: symbolLink,
      matchingSuffix: true,
      fetchSymbolGraph: { location in
        guard let uri = location.uri else { return nil }
        return try await workspace.primaryLanguageService(
          for: uri,
          workspace.buildServerManager.defaultLanguageInCanonicalTarget(for: uri)
        ).symbolGraph(forOnDiskContentsAt: location, in: workspace, manager: onDiskDocumentManager)
      }
    )
  }

  package func documentDiagnostic(_ req: DocumentDiagnosticsRequest) async throws -> DocumentDiagnosticReport {
    // VS Code does not request diagnostics again for a document if the diagnostics request failed, and a failure here
    // would also fail the diagnostics that are combined with other language services. Return empty results instead.
    guard let snapshot = try? documentManager.latestSnapshot(req.textDocument.uri) else {
      return .full(RelatedFullDocumentDiagnosticReport(items: []))
    }
    let diagnostics = await symbolLinkDiagnostics(for: snapshot)
    // Diagnostics computation stops early when cancelled. Don't return the partial results to the client.
    try Task.checkCancellation()
    return .full(RelatedFullDocumentDiagnosticReport(items: diagnostics))
  }

  package func indexDidBecomeUpToDate() async {
    guard let sourceKitLSPServer else {
      return
    }
    var needsRefresh = false
    for uri in documentsWithSymbolLinks {
      guard let snapshot = try? documentManager.latestSnapshot(uri) else {
        continue
      }
      if await clientSupportsPullDiagnostics(for: snapshot.language) {
        needsRefresh = true
      } else {
        await schedulePublishSymbolLinkDiagnostics(for: snapshot)
      }
    }
    guard needsRefresh,
      await sourceKitLSPServer.capabilityRegistry?.clientCapabilities.workspace?.diagnostics?.refreshSupport ?? false
    else {
      return
    }
    Task {
      await orLog("Sending DiagnosticsRefreshRequest after index became up-to-date") {
        _ = try await sourceKitLSPServer.sendRequestToClient(DiagnosticsRefreshRequest())
      }
    }
  }

  private func clientSupportsPullDiagnostics(for language: LanguageServerProtocol.Language) async -> Bool {
    return await sourceKitLSPServer?.capabilityRegistry?.clientSupportsPullDiagnostics(for: language) ?? false
  }

  /// If the client doesn't pull diagnostics for the given document, compute its symbol link diagnostics after a short
  /// delay and publish them if they changed.
  func schedulePublishSymbolLinkDiagnostics(for snapshot: DocumentSnapshot) async {
    guard let sourceKitLSPServer, await !clientSupportsPullDiagnostics(for: snapshot.language) else {
      return
    }
    let uri = snapshot.uri
    inFlightPublishDiagnosticsTasks[uri]?.cancel()
    inFlightPublishDiagnosticsTasks[uri] = Task(priority: .medium) { [weak self] in
      do {
        // Any edit within the debounce duration cancels this task and schedules a new one.
        try await Task.sleep(for: sourceKitLSPServer.options.swiftPublishDiagnosticsDebounceDurationOrDefault)
      } catch {
        return
      }
      guard let self, let snapshot = try? await self.documentManager.latestSnapshot(uri) else {
        return
      }
      let diagnostics = await self.symbolLinkDiagnostics(for: snapshot)
      guard !Task.isCancelled else {
        return
      }
      await self.publish(diagnostics, for: uri)
    }
  }

  private func publish(_ diagnostics: [Diagnostic], for uri: DocumentURI) async {
    guard diagnostics != publishedDiagnostics[uri] ?? [] else {
      return
    }
    publishedDiagnostics[uri] = diagnostics
    await sourceKitLSPServer?.publishDiagnostics(diagnostics, for: uri, from: .documentation)
  }

  /// Diagnostics for the symbol links in the given document that can't be parsed or resolved.
  ///
  /// While the index is not up-to-date, symbol links that can't be resolved are not diagnosed since the symbol they
  /// refer to might not have been indexed yet. Once the index is up-to-date, the client is asked to refresh diagnostics.
  private func symbolLinkDiagnostics(for snapshot: DocumentSnapshot) async -> [Diagnostic] {
    if case .generatedInterface = try? ReferenceDocumentURL(from: snapshot.uri) {
      // Generated interfaces don't have diagnostics associated with them.
      return []
    }
    guard let sourceKitLSPServer, let workspace = await sourceKitLSPServer.workspaceForDocument(uri: snapshot.uri)
    else {
      return []
    }
    let symbolLinks = await symbolLinks(in: snapshot)
    if symbolLinks.isEmpty {
      documentsWithSymbolLinks.remove(snapshot.uri)
      return []
    }
    if sourceKitLSPServer.documentManager.openDocuments.contains(snapshot.uri) {
      documentsWithSymbolLinks.insert(snapshot.uri)
    }

    let indexIsUpToDate = (await workspace.semanticIndexManager?.progressStatus ?? .upToDate) == .upToDate
    let index = indexIsUpToDate ? await workspace.index(checkedFor: .deletedFiles) : nil
    return await sourceKitLSPServer.withOnDiskDocumentManager { onDiskDocumentManager in
      var diagnostics: [Diagnostic] = []
      for (destination, range) in symbolLinks {
        if Task.isCancelled {
          break
        }
        guard let symbolLink = DocCSymbolLink(linkString: destination) else {
          diagnostics.append(
            Diagnostic(
              range: range,
              severity: .warning,
              source: "DocC",
              message: "Failed to parse DocC symbol link '\(destination)'"
            )
          )
          continue
        }
        guard let index else {
          continue
        }
        do {
          if try await resolve(symbolLink, in: workspace, index: index, onDiskDocumentManager: onDiskDocumentManager)
            == nil
          {
            diagnostics.append(
              Diagnostic(
                range: range,
                severity: .warning,
                source: "DocC",
                message: "No symbol link resolved for '\(destination)'"
              )
            )
          }
        } catch {
          logger.debug("Failed to resolve DocC symbol link '\(destination)': \(error.forLogging)")
        }
      }
      return diagnostics
    }
  }

  /// The destination and range of every symbol link in the given document.
  ///
  /// For Swift files, these are the symbol links in documentation comments.
  private func symbolLinks(in snapshot: DocumentSnapshot) async -> [(destination: String, range: Range<Position>)] {
    switch snapshot.language {
    case .swift:
      guard let tree = await sourceKitLSPServer?.syntaxTreeManager.syntaxTree(for: snapshot) else {
        return []
      }
      return tree.tokens(viewMode: .sourceAccurate).flatMap { token in
        [
          token.leadingTrivia.docCommentLines(startingAt: token.position),
          token.trailingTrivia.docCommentLines(startingAt: token.endPositionBeforeTrailingTrivia),
        ].compactMap { $0 }.flatMap { symbolLinks(inDocComment: $0, snapshot: snapshot) }
      }
    case .markdown, .tutorial:
      var collector = SymbolLinkCollector()
      collector.visit(Markdown.Document(parsing: snapshot.text, options: [.parseSymbolLinks, .parseBlockDirectives]))
      return collector.links.map { destination, range in
        let lowerBound = snapshot.positionOf(
          zeroBasedLine: range.lowerBound.line - 1,
          utf8Column: range.lowerBound.column - 1
        )
        let upperBound = snapshot.positionOf(
          zeroBasedLine: range.upperBound.line - 1,
          utf8Column: range.upperBound.column - 1
        )
        return (destination, lowerBound..<upperBound)
      }
    default:
      return []
    }
  }

  private func symbolLinks(
    inDocComment lines: [Trivia.DocCommentLine],
    snapshot: DocumentSnapshot
  ) -> [(destination: String, range: Range<Position>)] {
    func position(of location: Markdown.SourceLocation) -> Position? {
      guard lines.indices.contains(location.line - 1) else {
        return nil
      }
      return snapshot.position(of: lines[location.line - 1].position.advanced(by: location.column - 1))
    }

    var collector = SymbolLinkCollector()
    collector.visit(Markdown.Document(parsing: lines.map(\.text).joined(separator: "\n"), options: [.parseSymbolLinks]))
    return collector.links.compactMap { destination, range in
      guard let lowerBound = position(of: range.lowerBound), let upperBound = position(of: range.upperBound) else {
        return nil
      }
      return (destination, lowerBound..<upperBound)
    }
  }
}
