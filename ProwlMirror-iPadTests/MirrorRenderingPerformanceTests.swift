import SwiftUI
import XCTest

@testable import ProwlMirror_iPad

@MainActor
final class MirrorRenderingPerformanceTests: XCTestCase {
  func testLargePlainTextLayoutBaseline() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousWindow?.makeKeyAndVisible()
    }
    let text = (0..<10_000).map {
      "Line \($0): terminal output with words, numbers 12345 and 中文内容."
    }
    .joined(separator: "\n")
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
      let controller = UIHostingController(rootView: ScrollView { MirrorDocumentView(text: text) })
      window.rootViewController = controller
      window.makeKeyAndVisible()
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
        XCTAssertTrue(
          controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Large plain text first viewport"
      attachment.lifetime = .keepAlways
      add(attachment)
      window.rootViewController = nil
    }
  }
}
