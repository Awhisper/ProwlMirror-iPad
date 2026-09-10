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
  private(set) var configuration: MirrorSavedConnection
  private(set) var panes: [MirrorPaneDescriptor] = []
  private(set) var pane: MirrorPaneDescriptor?
  private(set) var status: Status = .disconnected
  private(set) var text = ""
  private(set) var revision: UInt64 = 0
  private(set) var updatedAt: Date?
  private(set) var error: String?
  private(set) var supportsHistory = false
  private(set) var historyLines: [String] = []
  private(set) var historyOffset = 0
  private(set) var historyCapturedAt: Date?
  private(set) var historyTruncated = false
  private(set) var isLoadingHistory = false
  var showsHistory = false
  var liveReadingOffset: CGFloat = 0
  var historyReadingOffset: CGFloat = 0
  @ObservationIgnored private var historyID: UUID?
  @ObservationIgnored private var historyBytes = 0
  var draft = "" {
    didSet { if draft != oldValue { draftRevision = UUID() } }
  }
  private(set) var agentState: MirrorAgentState?
  private(set) var supportsSubmission = false
  var isComposing = false
  private(set) var submission: Submission?
  @ObservationIgnored private var draftRevision = UUID()
  @ObservationIgnored private var hostRunID: UUID?

  struct Submission {
    let id: UUID
    let text: String
    let paneID: UUID
    let runID: UUID
    let agentGeneration: UUID
    let draftRevision: UUID
    let configuration: MirrorSavedConnection
    var outcome: MirrorSubmitOutcome
  }

  var canSubmit: Bool {
    status == .live && supportsSubmission && !isComposing && agentState?.canSubmit == true
      && agentState?.generation != nil && subscriptionID != nil && hostRunID != nil
      && submission?.outcome.status != .pending && submission?.outcome.status != .unknown
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && draft.utf8.count <= MirrorWire.maximumInput
  }

  var submissionHint: String {
    if let submission, submission.outcome.status != .accepted { return submission.outcome.detail }
    if !supportsSubmission { return "This Host has not enabled message submission for this pane." }
    if status != .live { return "Reconnect to the pane before sending." }
    return agentState?.reason ?? "Waiting for Agent state…"
  }
  var followsLatest = true
  var onVerifiedConnection: ((MirrorSavedConnection) -> Void)?
  @ObservationIgnored private var transport: (any MirrorTransport)?
  @ObservationIgnored private var subscriptionID: UUID?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var intent: MirrorMessage.Intent = .ifFree
  @ObservationIgnored private var userDisconnected = false
  @ObservationIgnored private var supportsRefresh = false
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
    agentState = nil
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
        self.agentState = nil
        self.markDeliveryUncertain()
        self.isLoadingHistory = false
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
    guard transport == nil else { return }
    intent = takeover ? .takeover : .ifFree
    connect()
  }

  func foreground() {
    guard !userDisconnected else { return }
    if status == .disconnected {
      retry()
    } else if status == .live, supportsRefresh, let subscriptionID {
      send(MirrorMessage(version: 2, kind: .refresh, subscriptionID: subscriptionID))
      querySubmission()
    }
  }

  func updateConnection(_ configuration: MirrorSavedConnection) {
    disconnect()
    if self.configuration.address != configuration.address
      || self.configuration.port != configuration.port
    {
      pane = nil
      panes = []
      text = ""
      revision = 0
      updatedAt = nil
      liveReadingOffset = 0
      historyReadingOffset = 0
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
      showsHistory = false
    }
    self.configuration = configuration
    intent = .ifFree
    connect()
  }

  func disconnect() {
    userDisconnected = true
    generation = UUID()
    let old = transport
    transport = nil
    old?.onClose = nil
    old?.close(nil)
    subscriptionID = nil
    agentState = nil
    markDeliveryUncertain()
    isLoadingHistory = false
    status = .disconnected
  }

  func submitDraft() {
    guard canSubmit, let pane, let subscriptionID, let hostRunID,
      let state = agentState, let agentGeneration = state.generation
    else { return }
    let request = Submission(
      id: UUID(), text: draft, paneID: pane.id, runID: hostRunID,
      agentGeneration: agentGeneration, draftRevision: draftRevision, configuration: configuration,
      outcome: .init(status: .pending, detail: "Waiting for delivery confirmation…"))
    submission = request
    send(
      MirrorMessage(
        version: 2, kind: .submit, paneID: pane.id, text: draft,
        subscriptionID: subscriptionID, hostRunID: hostRunID, submissionID: request.id,
        agentGeneration: agentGeneration, observationRevision: state.revision))
  }

  func querySubmission() {
    guard let submission, transport != nil, submission.configuration == configuration,
      submission.outcome.status == .pending || submission.outcome.status == .unknown
    else { return }
    send(
      MirrorMessage(
        version: 2, kind: .submissionStatus, paneID: submission.paneID,
        hostRunID: submission.runID, submissionID: submission.id,
        agentGeneration: submission.agentGeneration))
  }

  func acknowledgeUnknownSubmission() {
    guard submission?.outcome.status == .unknown else { return }
    submission = nil
  }

  private func markDeliveryUncertain() {
    if submission?.outcome.status == .pending {
      submission?.outcome = .init(
        status: .unknown,
        detail: "Delivery is unconfirmed. Check the receipt or Host output before sending again.")
    }
  }

  func loadHistory(refresh: Bool = false) {
    guard status == .live, supportsHistory, !isLoadingHistory, let subscriptionID else { return }
    if refresh {
      historyReadingOffset = 0
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
    }
    guard historyID == nil || historyOffset > 0 else { return }
    isLoadingHistory = true
    showsHistory = true
    send(
      MirrorMessage(
        version: 2, kind: .history, historyID: historyID,
        offset: historyID == nil ? nil : historyOffset, subscriptionID: subscriptionID))
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
      supportsRefresh = message.capabilities?.contains("refresh") == true
      supportsHistory = message.capabilities?.contains("history") == true
      supportsSubmission =
        message.capabilities?.contains("submit-text") == true
        && message.capabilities?.contains("agent-state") == true
      if supportsSubmission { querySubmission() }
      panes = message.panes ?? []
      onVerifiedConnection?(configuration)
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
      hostRunID = message.hostRunID
      agentState = nil
      historyID = nil
      historyLines = []
      historyBytes = 0
      historyOffset = 0
      historyCapturedAt = nil
      isLoadingHistory = false
      showsHistory = false
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
    case .state:
      guard message.version == 2, subscriptionID != nil,
        message.subscriptionID == subscriptionID, let state = message.agentState,
        state.observedAt.isFinite
      else {
        invalidMessage()
        return
      }
      agentState = state
    case .submitResult:
      guard message.version == 2, var current = submission,
        current.configuration == configuration, message.submissionID == current.id,
        message.hostRunID == current.runID, message.paneID == current.paneID,
        message.agentGeneration == current.agentGeneration, let outcome = message.result
      else { return }
      // Final receipts cannot be downgraded by a delayed pending response.
      guard current.outcome.status == .pending || current.outcome.status == .unknown else { return }
      current.outcome = outcome
      submission = current
      if outcome.status == .accepted, current.draftRevision == draftRevision { draft = "" }
    case .historyPage:
      guard isLoadingHistory, message.version == 2, subscriptionID != nil,
        message.subscriptionID == subscriptionID, let id = message.historyID,
        let offset = message.offset, let lines = message.lines,
        let total = message.total, let capturedAt = message.capturedAt,
        total >= 0, total <= MirrorHistory.maximumBytes + 1,
        offset >= 0, offset <= total, capturedAt.isFinite, lines.count <= MirrorHistory.pageSize,
        offset + lines.count == (historyID == nil ? total : historyOffset),
        historyID == nil || historyID == id
      else {
        invalidMessage()
        return
      }
      let pageBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
      guard pageBytes <= MirrorHistory.maximumBytes + 1 - historyBytes else {
        invalidMessage()
        return
      }
      historyBytes += pageBytes
      historyID = id
      historyOffset = offset
      historyLines.insert(contentsOf: lines, at: 0)
      historyCapturedAt = Date(timeIntervalSince1970: capturedAt)
      historyTruncated = message.truncated ?? false
      isLoadingHistory = false
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
      if message.error?.hasPrefix("HISTORY_UNAVAILABLE") == true,
        message.subscriptionID == subscriptionID
      {
        isLoadingHistory = false
        error = message.error
        return
      }
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
