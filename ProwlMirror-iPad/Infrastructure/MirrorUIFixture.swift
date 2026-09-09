#if DEBUG
  import Foundation

  /// Explicit UI-test launch only. Network and Host behavior are tested separately.
  @MainActor
  enum MirrorUIFixture {
    static func session() -> MirrorSession {
      let channel = Channel()
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
      let pane = MirrorPaneDescriptor(
        id: UUID(), title: "UI Fixture · Codex", directory: "/fixture", busy: false,
        projectName: "UI Fixture", subtitle: "Codex · main")
      private let lease = UUID()
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
              capabilities: ["text-v1", "history", "refresh"]))
        case .subscribe:
          onMessage?(
            .init(
              version: 2, kind: .subscribed, paneID: pane.id, subscriptionID: lease,
              hostRunID: UUID()))
          frame()
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
              """, subscriptionID: lease))
      }
    }
  }
#endif
