#if DEBUG
  import Foundation

  /// Explicit UI-test launch only. Network and Host behavior are tested separately.
  @MainActor
  enum MirrorUIFixture {
    static func session(name: String = "UI Fixture", longOutput: Bool = false) -> MirrorSession {
      let channel = Channel(name: name, longOutput: longOutput)
      let session = MirrorSession(
        configuration: .init(
          address: "127.0.0.1", port: 7880, pairingKey: String(repeating: "a", count: 64)),
        makeTransport: { _ in channel })
      session.connect()
      session.select(channel.pane)
      return session
    }

    private final class Channel: MirrorTransport {
      var onReady: (() -> Void)?
      var onMessage: ((MirrorMessage) -> Void)?
      var onClose: ((String?) -> Void)?
      let pane: MirrorPaneDescriptor
      let longOutput: Bool
      init(name: String, longOutput: Bool) {
        self.longOutput = longOutput
        pane = MirrorPaneDescriptor(
          id: UUID(), title: "\(name) · Codex", directory: "/fixture", busy: false,
          projectName: name, subtitle: "Codex · main")
      }
      private let lease = UUID()
      private let run = UUID()
      private let agentGeneration = UUID()
      private let history = MirrorHistory(
        text: (1...401).map { "Retained line \($0)" }.joined(separator: "\n"), truncated: true)
      private var sequence: UInt64 = 0

      func start() { onReady?() }
      func close(_ reason: String?) { onClose?(reason) }

      func send(_ message: MirrorMessage, closeAfterSending: Bool) {
        switch message.kind {
        case .list:
          onMessage?(
            .init(
              kind: .panes, panes: [pane], selectedVersion: 2,
              capabilities: ["text-v1", "history", "refresh", "agent-state", "submit-text"]))
        case .subscribe:
          onMessage?(
            .init(
              version: 2, kind: .subscribed, paneID: pane.id, subscriptionID: lease,
              hostRunID: run))
          frame()
          onMessage?(
            .init(
              version: 2, kind: .state, subscriptionID: lease,
              agentState: .init(
                generation: agentGeneration, revision: 1, canSubmit: true,
                reason: "Ready to send", observedAt: 1)))
        case .submit:
          onMessage?(
            .init(
              version: 2, kind: .submitResult, paneID: pane.id,
              hostRunID: run, submissionID: message.submissionID, agentGeneration: agentGeneration,
              result: .init(status: .accepted, detail: "Fixture message delivered")))
          onMessage?(
            .init(
              version: 2, kind: .state, subscriptionID: lease,
              agentState: .init(
                generation: agentGeneration, revision: 2, canSubmit: false,
                reason: "Working", observedAt: 2)))
        case .refresh: frame()
        case .history:
          do {
            let page = try history.page(before: message.offset ?? history.lines.count)
            onMessage?(
              .init(
                version: 2, kind: .historyPage, historyID: history.id, offset: page.start,
                lines: page.lines, total: history.lines.count, subscriptionID: lease,
                capturedAt: history.capturedAt, truncated: history.truncated))
          } catch { onClose?(error.localizedDescription) }
        case .acknowledge: break
        default: onClose?("Unexpected fixture request")
        }
      }

      private func frame() {
        sequence += 1
        if CommandLine.arguments.contains("--mirror-ui-large-table-fixture") {
          let rows = (0..<10_000).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
          onMessage?(
            .init(
              version: 2, kind: .textFrame, sequence: sequence,
              text: "| Index | Value |\n| --- | --- |\n" + rows, subscriptionID: lease))
          return
        }
        let extra =
          longOutput
          ? (1...40).map { "\n```text\nLive marker \($0)\n```" }.joined() : ""
        onMessage?(
          .init(
            version: 2, kind: .textFrame, sequence: sequence,
            text: """
              **Live output**
              正在分析代码，当前内容可以复制。

              ```swift
              let greeting = "Hello iPad"
              print(greeting)
              ```

              | Platform | Status |
              | --- | --- |
              | iPad | Reading |
              | macOS | Host |
              """ + extra, subscriptionID: lease))
      }
    }
  }
#endif
