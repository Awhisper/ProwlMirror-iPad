import Foundation
import Network
import Testing

@testable import ProwlMirror_iPad

@MainActor
struct MirrorNativeTransportTests {
  @Test(.timeLimit(.minutes(1))) func nativeTLSDiscoversAndMirrorsHostText() async throws {
    let suite = "MirrorNativeTransport-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = Source()
    let host = MirrorHost(source: source, defaults: defaults)
    host.address = "127.0.0.1"
    host.port = String(UInt16.random(in: 49152...65535))
    let ready = AsyncStream.makeStream(of: Bool.self)
    host.onStarted = { ready.continuation.yield(true) }
    host.start()
    defer {
      host.stop()
      ready.continuation.finish()
    }
    var readiness = ready.stream.makeAsyncIterator()
    #expect(await readiness.next() == true)
    let connection = MirrorConnection(
      NWConnection(
        host: "127.0.0.1", port: .init(rawValue: UInt16(host.port)!)!,
        using: try MirrorConnection.parameters(pairingKey: host.pairingKey)))
    let received = AsyncStream.makeStream(of: MirrorMessage.self)
    connection.onMessage = { received.continuation.yield($0) }
    connection.onClose = { _ in received.continuation.finish() }
    connection.onReady = { connection.send(MirrorMessage(kind: .list, supportedVersions: [2, 1])) }
    connection.start()
    defer {
      connection.close()
      received.continuation.finish()
    }
    var messages = received.stream.makeAsyncIterator()
    let panes = try #require(await messages.next())
    #expect(panes.selectedVersion == 2)
    #expect(source.reads == 0)
    connection.send(
      MirrorMessage(
        version: 2, kind: .subscribe, paneID: source.id,
        representation: .text, intent: .takeover))
    let subscribed = try #require(await messages.next())
    #expect(subscribed.kind == .subscribed)
    let frame = try #require(await messages.next())
    #expect(frame.kind == .textFrame)
    #expect(frame.text == "思考中\nSwift + Kotlin")
    #expect(frame.subscriptionID == subscribed.subscriptionID)
    connection.send(
      MirrorMessage(
        version: 2, kind: .acknowledge, sequence: frame.sequence,
        subscriptionID: subscribed.subscriptionID))
    connection.send(
      MirrorMessage(version: 2, kind: .refresh, subscriptionID: subscribed.subscriptionID))
    let refreshed = try #require(await messages.next())
    #expect(refreshed.kind == .textFrame)
    #expect(refreshed.text == frame.text)
    #expect(refreshed.sequence == 2)
    #expect(refreshed.subscriptionID == subscribed.subscriptionID)
    #expect(host.subscriberCount == 1)
    connection.send(
      MirrorMessage(version: 2, kind: .history, subscriptionID: subscribed.subscriptionID))
    let history = try #require(await messages.next())
    #expect(history.kind == .historyPage)
    #expect(history.lines?.last == "history end")
    #expect(history.truncated == true)
    #expect(history.subscriptionID == subscribed.subscriptionID)
    #expect(history.capturedAt != nil)
    host.stop()
    #expect(await messages.next()?.reason == .hostStopped)
    #expect(source.panes().count == 1)
  }

  private final class Source: MirrorPaneSource {
    let id = UUID()
    var reads = 0
    var supportsBoundedHistory: Bool { true }
    func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
      .init(text: "older line\nhistory end", truncated: true)
    }
    func panes() -> [MirrorPaneDescriptor] {
      [.init(id: id, title: "Fixture", directory: "/fixture", busy: false)]
    }
    func snapshot(_ id: UUID) throws -> MirrorFrame { throw MirrorProtocolError.invalidMessage }
    func activeText(_ id: UUID) throws -> String {
      reads += 1
      return "思考中\nSwift + Kotlin"
    }
    func retainedText(_ id: UUID) throws -> String { throw MirrorProtocolError.invalidMessage }
    func write(_ bytes: Data, to id: UUID) throws { throw MirrorProtocolError.invalidMessage }
  }
}
