# ProwlMirror-iPad
Native iPad mirror client for Prowl

Open `ProwlMirror-iPad.xcodeproj` from the repository root.

```text
ProwlMirror-iPad.xcodeproj/  Xcode project
ProwlMirror-iPad/            SwiftUI app and assets
ProwlMirror-iPadTests/       Unit tests
ProwlMirror-iPadUITests/     UI tests
```

The current implementation supports protocol-v2 discovery, explicit pane takeover,
live text replacement, retry without taking over another client, and foreground
refresh. Code and table details open as a frozen copy while the main view continues
updating. Long ordinary text blocks use bounded, lazily drawn plain-text chunks
to avoid laying out the entire output at once. Their context menu copies the full
original block; short blocks retain inline Markdown styling. This first-viewport
optimization does not yet cover expanded code or table details.
Successful connection details are saved in the local Keychain.

Edit Connection updates the IP, port or pairing key; reconnecting does not take over
another device's pane. On Hosts with `refresh`, foreground refresh keeps the same
subscription and requests an unchanged frame again if necessary.

History is available when the Host advertises bounded history capture. It opens a
frozen snapshot with capture time and truncation information; loading earlier pages
preserves the reading position while live output continues updating separately.
Each pane keeps separate live and history reading positions when switching panes.
Changing the Host address clears the previous Host's history and reading positions.

The composer supports multiline drafts and explicit Send when the Host advertises
submission and reports the Agent ready. Pending or uncertain delivery blocks another
send. Reconnection queries the original receipt without replaying the text, and an
accepted receipt clears only a draft that has not been edited since submission.
The UIKit composer distinguishes marked text and physical key presses. A single
Return inserts a newline; two physical Returns within 350 ms submit when ready,
removing only the first key's inserted newline. Editing, selection changes, losing
focus, changed Agent state and IME composition cancel the pair. Software Return
does not trigger this shortcut. Pending submissions retain a viewable text copy.

This is an implementation checkpoint: the initial Codex adapter in the Mac Host
working branch has not completed build and runtime verification. The submission UI
and receipt handling are currently verified with deterministic test sources.
It requires the mobile-mirror Host changes in Prowl; an older
Host is reported as incompatible. Ghostty is not embedded in this client.

Run the unit, native TLS, and rotation UI tests with a signed iPad simulator build:

```sh
xcodebuild test -project ProwlMirror-iPad.xcodeproj -scheme ProwlMirror-iPad \
  -destination 'platform=iOS Simulator,name=Prowl Mirror iPad'
```

Keep simulator signing enabled so Keychain behavior can be tested. The transport
test uses the Prowl Host implementation with a deterministic text source; it does
not replace testing against a real Mac Host and agent session.

The Debug-only `--mirror-ui-fixture` launch argument supplies deterministic reading,
code, table and history data for UI tests. It does not connect to a real Host or
save credentials. UI tests also exercise connection editing and invalid-key feedback.

See `ThirdPartyNotices/` for the source and license of the Prowl-derived code.
