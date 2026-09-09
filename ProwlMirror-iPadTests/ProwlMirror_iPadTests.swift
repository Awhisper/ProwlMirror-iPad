import Foundation
import Testing

@testable import ProwlMirror_iPad

struct ProwlMirror_iPadTests {
  @Test func wirePreservesUnicodeAndRejectsUnboundedFrames() throws {
    let frame = MirrorMessage(
      version: 2, kind: .textFrame, sequence: 1, text: "思考\n结论", subscriptionID: UUID())
    let bytes = try MirrorWire.encode(frame)
    #expect(try MirrorWire.decode(bytes.dropFirst(4)).text == frame.text)
    #expect(throws: MirrorProtocolError.self) { try MirrorWire.length(Data([255, 255, 255, 255])) }
    #expect(throws: MirrorProtocolError.self) {
      try MirrorWire.decode(Data(#"{"version":99,"kind":"list"}"#.utf8))
    }
  }
}
