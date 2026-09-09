import Foundation
import Network
import Observation

@MainActor
protocol MirrorTransport: AnyObject {
  var onReady: (() -> Void)? { get set }
  var onMessage: ((MirrorMessage) -> Void)? { get set }
  var onClose: ((String?) -> Void)? { get set }
  func start()
  func send(_ message: MirrorMessage, closeAfterSending: Bool)
  func close(_ reason: String?)
}

extension MirrorConnection: MirrorTransport {}

@MainActor
@Observable
final class MirrorSession: Identifiable {
  enum Status: Equatable {
    case disconnected, connecting, choosingPane, subscribing, live, takenOver, hostStopped,
      paneClosed, incompatible

    var label: String {
      switch self {
      case .disconnected: "Connection lost"
      case .connecting: "Connecting…"
      case .choosingPane: "Choose a pane"
      case .subscribing: "Opening mirror…"
      case .live: "Live"
      case .takenOver: "Taken over by another device"
      case .hostStopped: "Host stopped sharing"
      case .paneClosed: "Host pane closed"
      case .incompatible: "Update Host required"
      }
    }
  }

  let id = UUID()
  let configuration: MirrorSavedConnection
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var pane: MirrorPaneDescriptor?
  private(set) var status: Status = .disconnected
  private(set) var text = ""
  private(set) var revision: UInt64 = 0
  private(set) var updatedAt: Date?
  private(set) var error: String?
  var draft = ""
  var followsLatest = true
  var onVerifiedConnection: (() -> Void)?
  @ObservationIgnored private var transport: (any MirrorTransport)?
  @ObservationIgnored private var subscriptionID: UUID?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var intent: MirrorMessage.Intent = .ifFree
  @ObservationIgnored private var userDisconnected = false
  @ObservationIgnored private let makeTransport:
    (MirrorSavedConnection) throws -> any MirrorTransport

  init(
    configuration: MirrorSavedConnection,
    makeTransport: @escaping (MirrorSavedConnection) throws -> any MirrorTransport = {
      configuration in
      guard configuration.port > 0 else { throw MirrorProtocolError.invalidMessage }
      return MirrorConnection(
        NWConnection(
          host: .init(configuration.address),
          port: .init(rawValue: configuration.port)!,
          using: try MirrorConnection.parameters(pairingKey: configuration.pairingKey)))
    }
  ) {
    self.configuration = configuration
    self.makeTransport = makeTransport
  }

  func connect() {
    guard transport == nil else { return }
    userDisconnected = false
    error = nil
    status = .connecting
    generation = UUID()
    let attempt = generation
    do {
      let channel = try makeTransport(configuration)
      transport = channel
      channel.onReady = { [weak self] in
        guard let self, self.generation == attempt else { return }
        self.send(MirrorMessage(kind: .list, supportedVersions: [2, 1]))
      }
      channel.onMessage = { [weak self] message in
        guard let self, self.generation == attempt else { return }
        self.receive(message)
      }
      channel.onClose = { [weak self] reason in
        guard let self, self.generation == attempt else { return }
        self.transport = nil
        self.subscriptionID = nil
        if self.status == .live || self.status == .connecting || self.status == .subscribing
          || self.status == .choosingPane
        {
          self.status = .disconnected
        }
        self.error = self.error ?? reason
      }
      channel.start()
    } catch {
      status = .disconnected
      self.error = error.localizedDescription
    }
  }

  func select(_ pane: MirrorPaneDescriptor) {
    guard status == .choosingPane else { return }
    self.pane = pane
    intent = .takeover
    subscribe()
  }

  func refreshPanes() {
    guard status == .choosingPane else { return }
    send(MirrorMessage(kind: .list, supportedVersions: [2, 1]))
  }

  func retry(takeover: Bool = false) {
    guard transport == nil, pane != nil else { return }
    intent = takeover ? .takeover : .ifFree
    connect()
  }

  func foreground() {
    guard !userDisconnected else { return }
    if status == .disconnected {
      retry()
    }
    // A fresh connection requests a full frame, even if the last revision is unchanged.
    else if status == .live {
      disconnect()
      retry()
    }
  }

  func disconnect() {
    userDisconnected = true
    generation = UUID()
    let old = transport
    transport = nil
    old?.onClose = nil
    old?.close(nil)
    subscriptionID = nil
    status = .disconnected
  }

  private func subscribe() {
    guard let pane else { return }
    status = .subscribing
    revision = 0
    subscriptionID = nil
    send(
      MirrorMessage(
        version: 2, kind: .subscribe, paneID: pane.id, representation: .text, intent: intent))
  }

  private func send(_ message: MirrorMessage) { transport?.send(message, closeAfterSending: false) }

  private func receive(_ message: MirrorMessage) {
    switch message.kind {
    case .panes:
      guard message.selectedVersion == 2, message.capabilities?.contains("text-v1") == true else {
        status = .incompatible
        error = "Update Prowl on this Host to enable mobile text mirrors."
        transport?.close(nil)
        return
      }
      panes = message.panes ?? []
      onVerifiedConnection?()
      if let pane {
        guard panes.contains(where: { $0.id == pane.id }) else {
          status = .paneClosed
          transport?.close(nil)
          return
        }
        subscribe()
      } else {
        status = .choosingPane
      }
    case .subscribed:
      guard status == .subscribing, message.version == 2, message.paneID == pane?.id,
        message.hostRunID != nil, let lease = message.subscriptionID
      else {
        invalidMessage()
        return
      }
      subscriptionID = lease
    case .textFrame:
      guard message.version == 2, let lease = subscriptionID, message.subscriptionID == lease,
        let sequence = message.sequence, sequence > revision, let replacement = message.text,
        replacement.utf8.count <= MirrorWire.maximumPayload / 8
      else {
        invalidMessage()
        return
      }
      text = replacement
      revision = sequence
      updatedAt = Date()
      status = .live
      send(MirrorMessage(version: 2, kind: .acknowledge, sequence: sequence, subscriptionID: lease))
    case .ended:
      guard let reason = message.reason else {
        invalidMessage()
        return
      }
      switch reason {
      case .takenOver: status = .takenOver
      case .hostStopped: status = .hostStopped
      case .paneClosed: status = .paneClosed
      }
      transport?.close(nil)
    case .failure:
      if message.error?.hasPrefix("PANE_BUSY") == true { status = .takenOver }
      error = message.error ?? "Host rejected the request."
      transport?.close(nil)
    default: invalidMessage()
    }
  }

  private func invalidMessage() {
    error = "Host sent an invalid mirror message."
    transport?.close(error)
  }
}
