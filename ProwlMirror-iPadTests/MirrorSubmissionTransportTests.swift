import Foundation
import Network
import Testing

@testable import ProwlMirror_iPad

@MainActor
struct MirrorSubmissionTransportTests {
  @Test(.timeLimit(.minutes(1))) func pendingDeliverySurvivesTakeoverAndReadOnlyReceiptQuery()
    async throws
  {
    let suite = "MirrorPendingTakeover-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = Source()
    source.holdsDelivery = true
    let started = AsyncStream.makeStream(of: Bool.self)
    source.onDeliveryStarted = { started.continuation.yield(true) }
    let host = MirrorHost(source: source, defaults: defaults)
    host.address = "127.0.0.1"
    host.port = String(UInt16.random(in: 49152...65535))
    let ready = AsyncStream.makeStream(of: Bool.self)
    host.onStarted = { ready.continuation.yield(true) }
    host.start()
    defer {
      source.finishDelivery()
      host.stop()
      ready.continuation.finish()
      started.continuation.finish()
    }
    var readiness = ready.stream.makeAsyncIterator()
    #expect(await readiness.next() == true)
    let first = try peer(host)
    let second = try peer(host)
    let observer = try peer(host)
    defer {
      first.connection.close()
      second.connection.close()
      observer.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    var observerMessages = observer.messages.makeAsyncIterator()
    #expect(await firstMessages.next()?.kind == .panes)
    #expect(await secondMessages.next()?.kind == .panes)
    #expect(await observerMessages.next()?.kind == .panes)
    first.connection.send(
      .init(
        version: 2, kind: .subscribe, paneID: source.id,
        representation: .text, intent: .takeover))
    let lease = try #require(await firstMessages.next())
    #expect(await firstMessages.next()?.kind == .textFrame)
    let state = try #require(await firstMessages.next()?.agentState)
    let requestID = UUID()
    first.connection.send(
      .init(
        version: 2, kind: .submit, paneID: source.id, text: "pending",
        subscriptionID: lease.subscriptionID, hostRunID: lease.hostRunID, submissionID: requestID,
        agentGeneration: state.generation, observationRevision: state.revision))
    var deliveryStart = started.stream.makeAsyncIterator()
    #expect(await deliveryStart.next() == true)
    second.connection.send(
      .init(
        version: 2, kind: .subscribe, paneID: source.id,
        representation: .text, intent: .takeover))
    let secondLease = try #require(await secondMessages.next())
    #expect(secondLease.kind == .subscribed)
    #expect(secondLease.subscriptionID != lease.subscriptionID)
    #expect(await secondMessages.next()?.kind == .textFrame)
    #expect(await secondMessages.next()?.agentState?.canSubmit == false)
    var receivedTakeover = false
    while let message = await firstMessages.next() {
      if message.kind == .ended {
        #expect(message.reason == .takenOver)
        receivedTakeover = true
        break
      }
      #expect(message.kind == .state)
    }
    #expect(receivedTakeover)
    let query = MirrorMessage(
      version: 2, kind: .submissionStatus, paneID: source.id,
      hostRunID: lease.hostRunID, submissionID: requestID, agentGeneration: state.generation)
    observer.connection.send(query)
    #expect(try await nextResult(&observerMessages).result?.status == .pending)
    #expect(host.subscriberCount == 1)
    source.finishDelivery()
    var result: MirrorSubmitOutcome.Status?
    for _ in 0..<10 {
      observer.connection.send(query)
      result = try await nextResult(&observerMessages).result?.status
      if result != .pending { break }
    }
    #expect(result == .accepted)
    #expect(host.subscriberCount == 1)
    #expect(source.deliveries == 1)
  }

  private func peer(_ host: MirrorHost) throws -> (
    connection: MirrorConnection, messages: AsyncStream<MirrorMessage>
  ) {
    let connection = MirrorConnection(
      NWConnection(
        host: "127.0.0.1",
        port: .init(rawValue: UInt16(host.port)!)!,
        using: try MirrorConnection.parameters(pairingKey: host.pairingKey)))
    let stream = AsyncStream.makeStream(of: MirrorMessage.self)
    connection.onMessage = { stream.continuation.yield($0) }
    connection.onClose = { _ in stream.continuation.finish() }
    connection.onReady = { connection.send(.init(kind: .list, supportedVersions: [2])) }
    connection.start()
    return (connection, stream.stream)
  }

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
    var holdsDelivery = false
    var onDeliveryStarted: (() -> Void)?
    private var delivery: CheckedContinuation<MirrorSubmitOutcome, Never>?

    func finishDelivery() {
      let pending = delivery
      delivery = nil
      pending?.resume(returning: .init(status: .accepted, detail: "Fixture accepted"))
    }
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
      if holdsDelivery {
        return await withCheckedContinuation { continuation in
          delivery = continuation
          onDeliveryStarted?()
        }
      }
      return .init(status: .accepted, detail: "Fixture accepted")
    }
    func activeText(_ id: UUID) throws -> String { "Fixture output" }
    func retainedText(_ id: UUID) throws -> String { "Fixture output" }
    func snapshot(_ id: UUID) throws -> MirrorFrame { throw MirrorProtocolError.invalidMessage }
    func write(_ bytes: Data, to id: UUID) throws { throw MirrorProtocolError.invalidMessage }
  }
}
