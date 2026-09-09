import Foundation
import Testing

@testable import ProwlMirror_iPad

@MainActor
struct MirrorSessionTests {
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
