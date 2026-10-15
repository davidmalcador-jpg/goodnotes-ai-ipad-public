import XCTest
import UIKit
import PDFKit
@testable import NoteAssistant

final class DocumentPreviewTests: XCTestCase {
    @MainActor
    func testImageInitiallyFitsHalfWidthAndPreservesZoomAfterResize() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 2200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 2200))
        }
        let view = CitationImageView(frame: CGRect(x: 0, y: 0, width: 340, height: 800))
        view.open(image)
        view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(view.imageView.frame.width, view.bounds.width + 0.5)
        XCTAssertLessThanOrEqual(view.imageView.frame.height, view.bounds.height + 0.5)
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale, accuracy: 0.001)
        XCTAssertNotNil(view.viewForZooming(in: view))

        view.setZoomScale(view.minimumZoomScale * 2, animated: false)
        XCTAssertEqual(view.zoomScale / view.minimumZoomScale, 2, accuracy: 0.01)
        let equivalent = try XCTUnwrap(UIImage(data: XCTUnwrap(image.pngData())))
        XCTAssertEqual(equivalent.size, image.size)
        view.open(equivalent)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale / view.minimumZoomScale, 2, accuracy: 0.01)

        view.frame.size = CGSize(width: 600, height: 800)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale / view.minimumZoomScale, 2, accuracy: 0.01)
    }

    @MainActor
    func testCitationNavigationAfterPresentationAndResize() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        try renderer.pdfData { context in
            for number in 1...24 {
                context.beginPage()
                ("Distinct source page \(number)" as NSString).draw(at: CGPoint(x: 30, y: 30),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }.write(to: file)

        let view = CitationPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        // Match SwiftUI: load before the view is attached or assigned its sheet size.
        view.open(url: file, pageNumber: 18)
        let controller = UIViewController()
        controller.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.layoutIfNeeded()
        for _ in 0..<100 {
            if view.currentPage.flatMap({ view.document?.index(for: $0) }) == 17 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 17)
        XCTAssertTrue(view.currentPage?.string?.contains("Distinct source page 18") == true)

        let next = try XCTUnwrap(view.document?.page(at: 18))
        view.go(to: next)
        // A normal SwiftUI update or rotation must preserve subsequent manual browsing.
        view.open(url: file, pageNumber: 18)
        window.frame.size = CGSize(width: 800, height: 600)
        view.frame = window.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 18)
    }
}
