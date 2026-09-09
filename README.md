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
updating. Successful connection details are saved in the local Keychain.

Edit Connection updates the IP, port or pairing key; reconnecting does not take over
another device's pane. On Hosts with `refresh`, foreground refresh keeps the same
subscription and requests an unchanged frame again if necessary.

This is an implementation checkpoint: message submission and remote history are
not available yet. It requires the mobile-mirror Host changes in Prowl; an older
Host is reported as incompatible. Ghostty is not embedded in this client.

Run the unit, native TLS, and rotation UI tests with a signed iPad simulator build:

```sh
xcodebuild test -project ProwlMirror-iPad.xcodeproj -scheme ProwlMirror-iPad \
  -destination 'platform=iOS Simulator,name=Prowl Mirror iPad'
```

Keep simulator signing enabled so Keychain behavior can be tested. The transport
test uses the Prowl Host implementation with a deterministic text source; it does
not replace testing against a real Mac Host and agent session.

See `ThirdPartyNotices/` for the source and license of the Prowl-derived code.
