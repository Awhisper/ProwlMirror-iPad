import Foundation
import Testing

@testable import ProwlMirror_iPad

@MainActor
struct MirrorSessionTests {
  @Test func receiptDoesNotClearAnEditedDraftOrRepeatSubmission() throws {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    let listing = MirrorMessage(
      kind: .panes, panes: [pane], selectedVersion: 2,
      capabilities: ["text-v1", "agent-state", "submit-text"])
    transport.onMessage?(listing)
    session.select(pane)
    let lease = UUID()
    let run = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .subscribed, paneID: pane.id,
        subscriptionID: lease, hostRunID: run))
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 1,
        text: "Ready", subscriptionID: lease))
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .state, subscriptionID: lease,
        agentState: .init(
          generation: UUID(), revision: 1, canSubmit: true, reason: "Ready", observedAt: 1)))
    session.draft = "first\nsecond"
    #expect(session.canSubmit)
    session.submitDraft()
    session.submitDraft()
    #expect(transport.sent.filter { $0.kind == .submit }.count == 1)
    let request = try #require(transport.sent.last)
    session.draft = "changed"
    #expect(session.submission?.text == "first\nsecond")
    session.draft = "first\nsecond"
    transport.onClose?("Lost")
    #expect(session.submission?.outcome.status == .unknown)
    session.retry()
    transport.onMessage?(listing)
    #expect(transport.sent.filter { $0.kind == .submit }.count == 1)
    #expect(
      transport.sent.contains {
        $0.kind == .submissionStatus && $0.submissionID == request.submissionID
      })
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .submitResult, paneID: pane.id,
        hostRunID: run, submissionID: request.submissionID,
        agentGeneration: request.agentGeneration,
        result: .init(status: .accepted, detail: "Delivered")))
    #expect(session.draft == "first\nsecond")
    #expect(session.submission?.outcome.status == .accepted)
  }

  @Test func acceptedReceiptClearsOnlyTheUnchangedDraft() throws {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      MirrorMessage(
        kind: .panes, panes: [pane], selectedVersion: 2,
        capabilities: ["text-v1", "agent-state", "submit-text"]))
    session.select(pane)
    let lease = UUID()
    let run = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .subscribed, paneID: pane.id,
        subscriptionID: lease, hostRunID: run))
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 1,
        text: "Ready", subscriptionID: lease))
    session.draft = "message"
    #expect(!session.canSubmit)
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .state, subscriptionID: lease,
        agentState: .init(
          generation: UUID(), revision: 1, canSubmit: false, reason: "Busy", observedAt: 1)))
    #expect(!session.canSubmit)
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .state, subscriptionID: lease,
        agentState: .init(
          generation: UUID(), revision: 2, canSubmit: true, reason: "Ready", observedAt: 2)))
    session.submitDraft()
    let request = try #require(transport.sent.last)
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .submitResult, paneID: pane.id,
        hostRunID: run, submissionID: request.submissionID,
        agentGeneration: request.agentGeneration,
        result: .init(status: .accepted, detail: "Delivered")))
    #expect(session.draft.isEmpty)
  }

  @Test func historyPagesStayFrozenAndDoNotReplaceLiveOutput() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      MirrorMessage(
        kind: .panes, panes: [pane], selectedVersion: 2,
        capabilities: ["text-v1", "history"]))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .subscribed, paneID: pane.id,
        subscriptionID: lease, hostRunID: UUID()))
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 1,
        text: "live", subscriptionID: lease))
    session.loadHistory(refresh: true)
    let history = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .historyPage, historyID: history,
        offset: 1, lines: ["last"], total: 2, subscriptionID: lease, capturedAt: 100,
        truncated: true))
    session.loadHistory()
    #expect(transport.sent.last?.historyID == history)
    #expect(transport.sent.last?.offset == 1)
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .historyPage, historyID: history,
        offset: 0, lines: ["first"], total: 2, subscriptionID: lease, capturedAt: 100,
        truncated: true))
    #expect(session.historyLines == ["first", "last"])
    #expect(session.historyTruncated)
    #expect(session.text == "live")
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 2,
        text: "new live", subscriptionID: lease))
    #expect(session.historyLines == ["first", "last"])
    #expect(session.text == "new live")
    session.liveReadingOffset = 300
    session.historyReadingOffset = 200
    session.updateConnection(
      .init(
        address: "192.0.2.1", port: 7880,
        pairingKey: String(repeating: "a", count: 64)))
    #expect(session.historyLines.isEmpty)
    #expect(!session.showsHistory)
    #expect(session.liveReadingOffset == 0)
    #expect(session.historyReadingOffset == 0)
  }

  @Test func foregroundRefreshKeepsLeaseAndConnection() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      MirrorMessage(
        kind: .panes, panes: [pane], selectedVersion: 2,
        capabilities: ["text-v1", "refresh"]))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .subscribed, paneID: pane.id,
        subscriptionID: lease, hostRunID: UUID()))
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 1,
        text: "current", subscriptionID: lease))
    session.foreground()
    #expect(transport.starts == 1)
    #expect(transport.sent.last?.kind == .refresh)
    #expect(transport.sent.last?.subscriptionID == lease)
    #expect(session.text == "current")
  }

  @Test func editingKeyUsesIfFreeAndSavesOnlyVerifiedNewConfiguration() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    var verified: MirrorSavedConnection?
    session.onVerifiedConnection = { verified = $0 }
    session.connect()
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    let listing = MirrorMessage(
      kind: .panes, panes: [pane], selectedVersion: 2, capabilities: ["text-v1"])
    transport.onMessage?(listing)
    session.select(pane)
    session.draft = "keep this"
    let replacement = MirrorSavedConnection(
      address: "127.0.0.1", port: 7880,
      pairingKey: String(repeating: "b", count: 64))
    session.updateConnection(replacement)
    #expect(verified != replacement)
    transport.onMessage?(listing)
    #expect(verified == replacement)
    #expect(transport.sent.last?.intent == .ifFree)
    #expect(session.draft == "keep this")
  }

  @Test func retryIsIfFreeAndRepeatedClicksDoNotOpenMoreConnections() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    let listing = MirrorMessage(
      kind: .panes, panes: [pane], selectedVersion: 2, capabilities: ["text-v1"])
    session.connect()
    transport.onMessage?(listing)
    session.select(pane)
    #expect(transport.sent.last?.intent == .takeover)
    transport.onClose?("Network lost")
    session.retry()
    session.retry()
    #expect(transport.starts == 2)
    transport.onMessage?(listing)
    #expect(transport.sent.last?.intent == .ifFree)
    transport.onMessage?(MirrorMessage(kind: .failure, error: "PANE_BUSY"))
    session.foreground()
    #expect(transport.starts == 2)
    session.retry(takeover: true)
    transport.onMessage?(listing)
    #expect(transport.sent.last?.intent == .takeover)
    #expect(transport.starts == 3)
  }

  @Test func replacementsClearOldOutputAndAcknowledgeWithoutAView() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      MirrorMessage(kind: .panes, panes: [pane], selectedVersion: 2, capabilities: ["text-v1"]))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .subscribed, paneID: pane.id,
        subscriptionID: lease, hostRunID: UUID()))
    session.draft = "未发送\n第二行"
    transport.onMessage?(
      MirrorMessage(
        version: 2, kind: .textFrame, sequence: 1, text: "thinking", subscriptionID: lease))
    transport.onMessage?(
      MirrorMessage(version: 2, kind: .textFrame, sequence: 2, text: "", subscriptionID: lease))
    #expect(session.text == "")
    #expect(session.draft == "未发送\n第二行")
    #expect(transport.sent.filter { $0.kind == .acknowledge }.count == 2)
    #expect(session.status == .live)
    transport.onMessage?(MirrorMessage(version: 2, kind: .ended, reason: .takenOver))
    session.foreground()
    #expect(session.status == .takenOver)
    #expect(transport.starts == 1)
  }

  @Test func cancelledAttemptCannotRestoreSubscription() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    session.connect()
    let stale = transport.onMessage
    session.disconnect()
    stale?(MirrorMessage(kind: .panes, panes: [], selectedVersion: 2, capabilities: ["text-v1"]))
    #expect(session.status == .disconnected)
    session.foreground()
    #expect(transport.starts == 1)
  }

  private func makeSession(_ transport: FakeTransport) -> MirrorSession {
    MirrorSession(
      configuration: .init(
        address: "127.0.0.1", port: 7880, pairingKey: String(repeating: "a", count: 64)),
      makeTransport: { _ in transport })
  }

  private final class FakeTransport: MirrorTransport {
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var sent: [MirrorMessage] = []
    var starts = 0
    func start() {
      starts += 1
      onReady?()
    }
    func send(_ message: MirrorMessage, closeAfterSending: Bool) { sent.append(message) }
    func close(_ reason: String?) { onClose?(reason) }
  }
}
