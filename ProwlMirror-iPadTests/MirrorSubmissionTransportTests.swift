import Foundation
import Network
import Testing

@testable import ProwlMirror_iPad

@MainActor
struct MirrorSubmissionTransportTests {
  @Test(.timeLimit(.minutes(1))) func duplicateSubmissionAndReceiptQueryNeverRepeatDelivery()
    async throws
  {
    let suite = "MirrorSubmissionTransport-\(UUID())"
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
    connection.onReady = { connection.send(MirrorMessage(kind: .list, supportedVersions: [2])) }
    connection.start()
    defer {
      connection.close()
      received.continuation.finish()
    }
    var messages = received.stream.makeAsyncIterator()
    let listing = try #require(await messages.next())
    #expect(listing.capabilities?.contains("submit-text") == true)
    connection.send(
      MirrorMessage(
        version: 2, kind: .subscribe, paneID: source.id,
        representation: .text, intent: .takeover))
    let lease = try #require(await messages.next())
    #expect(lease.kind == .subscribed)
    #expect(await messages.next()?.kind == .textFrame)
    let state = try #require(await messages.next()?.agentState)
    var request = MirrorMessage(
      version: 2, kind: .submit, paneID: source.id,
      text: "多行\nmessage", subscriptionID: lease.subscriptionID, hostRunID: lease.hostRunID,
      submissionID: UUID(), agentGeneration: state.generation, observationRevision: state.revision)
    connection.send(request)
    #expect(try await nextResult(&messages).result?.status == .accepted)
    connection.send(request)
    #expect(try await nextResult(&messages).result?.status == .accepted)
    #expect(source.deliveries == 1)
    request.submissionID = UUID()
    connection.send(request)
    #expect(try await nextResult(&messages).result?.status == .rejected)
    #expect(source.deliveries == 1)
    connection.send(
      MirrorMessage(
        version: 2, kind: .submissionStatus, paneID: source.id,
        hostRunID: lease.hostRunID, submissionID: UUID(), agentGeneration: state.generation))
    #expect(try await nextResult(&messages).result?.status == .unknown)
    #expect(source.deliveries == 1)
    source.observationRevision = 1
    request.submissionID = UUID()
    request.observationRevision = 1
    connection.send(request)
    #expect(try await nextResult(&messages).result?.status == .accepted)
    #expect(source.deliveries == 2)
  }

  private func nextResult(_ messages: inout AsyncStream<MirrorMessage>.Iterator) async throws
    -> MirrorMessage
  {
    while let message = await messages.next(isolation: MainActor.shared) {
      if message.kind == .submitResult { return message }
      #expect(message.kind == .state)
    }
    throw MirrorProtocolError.invalidMessage
  }

  private final class Source: MirrorPaneSource {
    let id = UUID()
    let generation = UUID()
    var deliveries = 0
    var observationRevision: UInt64 = 0
    var supportsSubmission: Bool { true }
    func panes() -> [MirrorPaneDescriptor] {
      [.init(id: id, title: "Submission fixture", directory: "/fixture", busy: false)]
    }
    func submissionState(_ id: UUID) -> MirrorAgentState {
      .init(
        generation: generation, revision: observationRevision, canSubmit: true,
        reason: "Detector has not observed the delivery yet", observedAt: 0)
    }
    func submit(_ text: String, to id: UUID, expected: MirrorAgentState) async
      -> MirrorSubmitOutcome
    {
      guard expected == submissionState(id), expected.canSubmit else {
        return .init(status: .rejected, detail: "State changed")
      }
      deliveries += 1
      return .init(status: .accepted, detail: "Fixture accepted")
    }
    func activeText(_ id: UUID) throws -> String { "Fixture output" }
    func retainedText(_ id: UUID) throws -> String { "Fixture output" }
    func snapshot(_ id: UUID) throws -> MirrorFrame { throw MirrorProtocolError.invalidMessage }
    func write(_ bytes: Data, to id: UUID) throws { throw MirrorProtocolError.invalidMessage }
  }
}
