import SwiftUI

struct MirrorPairingCodeField: View {
  @Binding var key: String
  @State private var first = ""
  @State private var second = ""
  @State private var legacy = false
  @FocusState private var focused: Int?

  var body: some View {
    VStack(alignment: .leading) {
      if legacy {
        SecureField("Pairing Key", text: $key)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Use Short Code") {
          key = ""
          legacy = false
        }
      } else {
        Text("Pairing Code").font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("ABCD", text: part(0))
            .focused($focused, equals: 0)
            .accessibilityLabel("Pairing code first half")
            .accessibilityIdentifier("pairing-code-first")
          Text("–").accessibilityHidden(true)
          TextField("2345", text: part(1))
            .focused($focused, equals: 1)
            .accessibilityLabel("Pairing code second half")
            .accessibilityIdentifier("pairing-code-second")
        }
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.characters).autocorrectionDisabled()
        .keyboardType(.asciiCapable)
        Button("Use Legacy Key") {
          key = ""
          legacy = true
        }
        .font(.caption)
      }
    }
    .onAppear { synchronize() }
    .onChange(of: key) { _, _ in synchronize() }
  }

  private func part(_ index: Int) -> Binding<String> {
    Binding(
      get: { index == 0 ? first : second },
      set: { value in
        let previous = index == 0 ? first : second
        let text = value.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard text != previous else { return }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).count == 64 {
          key = value.trimmingCharacters(in: .whitespacesAndNewlines)
          legacy = true
        } else if text.count > 4 {
          // Pasting the whole code in either field fills both halves.
          first = String(text.prefix(4))
          second = String(text.dropFirst(4))
          key = first + "-" + second
          focused = 1
        } else {
          if index == 0 { first = text } else { second = text }
          key = first + "-" + second
          // Only advance during initial entry; editing a saved code must keep its cursor.
          if index == 0, previous.count < 4, text.count == 4, second.isEmpty {
            focused = 1
          }
        }
      })
  }

  private func synchronize() {
    guard !legacy, key.count != 64 else {
      legacy = true
      return
    }
    let parts = key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2 {
      first = String(parts[0])
      second = String(parts[1])
    } else {
      first = String(key.prefix(4))
      second = String(key.dropFirst(4))
    }
  }
}
