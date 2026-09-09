import Foundation
import Testing

@testable import ProwlMirror_iPad

struct MirrorSubmissionLedgerTests {
  private func key(pane: UUID = UUID()) -> MirrorSubmissionLedger.Key {
    .init(run: UUID(), pane: pane, generation: UUID(), submission: UUID())
  }

  @Test func duplicateRetainsPendingAndFinalReceipt() {
    var ledger = MirrorSubmissionLedger()
    let id = key()
    guard case .reserved = ledger.reserve(id, text: "hello") else {
      Issue.record("First request must reserve delivery")
      return
    }
    guard case .existing(let pending) = ledger.reserve(id, text: "hello") else {
      Issue.record("Duplicate must reuse its receipt")
      return
    }
    #expect(pending.status == .pending)
    ledger.finish(id, outcome: .init(status: .accepted, detail: "Delivered"))
    ledger.finish(id, outcome: .init(status: .rejected, detail: "Late result"))
    guard case .existing(let final) = ledger.reserve(id, text: "hello") else {
      Issue.record("Completed request must not reserve delivery again")
      return
    }
    #expect(final.status == .accepted)
    guard case .refused = ledger.reserve(id, text: "different") else {
      Issue.record("Reusing an ID for another body must fail")
      return
    }
  }

  @Test func pendingDeliveryCannotBeEvictedOrOverlapped() {
    var ledger = MirrorSubmissionLedger(capacity: 1)
    let first = key()
    _ = ledger.reserve(first, text: "first")
    for next in [key(pane: first.pane), key()] {
      guard case .refused = ledger.reserve(next, text: "next") else {
        Issue.record("Pending delivery must remain protected")
        return
      }
    }
    #expect(ledger.receipt(first).status == .pending)
    ledger.finish(first, outcome: .init(status: .accepted, detail: "Delivered"))
    guard case .reserved = ledger.reserve(key(), text: "next") else {
      Issue.record("Completed receipt may be evicted")
      return
    }
    #expect(ledger.receipt(first).status == .unknown)
  }

  @Test func concurrentDeliveryLimitDoesNotLoseReceipts() {
    var ledger = MirrorSubmissionLedger()
    let pending = (0..<16).map { _ in key() }
    for id in pending { _ = ledger.reserve(id, text: "message") }
    guard case .refused = ledger.reserve(key(), text: "overflow") else {
      Issue.record("Concurrent deliveries must be bounded")
      return
    }
    #expect(pending.allSatisfy { ledger.receipt($0).status == .pending })
  }

  @Test func inputValidationUsesUTF8BytesAndRejectsTerminalControls() {
    #expect(MirrorSubmissionLedger.validText("多行\n\t代码"))
    #expect(MirrorSubmissionLedger.validText(String(repeating: "a", count: 65536)))
    for text in [
      "", " \n\t", "hello\r", "\u{1B}[2J", "a\u{7F}", "a\u{85}",
      String(repeating: "中", count: 21846),
    ] {
      #expect(!MirrorSubmissionLedger.validText(text))
    }
  }
}
