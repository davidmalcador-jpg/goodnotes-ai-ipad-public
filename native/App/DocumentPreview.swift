import SwiftUI
import PDFKit
import UIKit

struct DocumentPreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let pageNumber: Int
    let version: Int
}

struct DocumentPreview: View {
    let request: DocumentPreviewRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if request.url.pathExtension.lowercased() == "pdf" {
                    PDFPagePreview(url: request.url, pageNumber: request.pageNumber)
                } else if let cgImage = try? DocumentProcessor.downsampledImage(url: request.url) {
                    ImagePagePreview(image: UIImage(cgImage: cgImage))
                } else {
                    ContentUnavailableView("无法显示资料", systemImage: "doc.badge.ellipsis", description: Text("文件已移除或格式无法预览. 请重新导入资料."))
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(request.title).font(.headline).lineLimit(1)
                        Text(request.url.pathExtension.lowercased() == "pdf"
                             ? "PDF 第 \(request.pageNumber) 页 · v\(request.version)"
                             : "图片 · v\(request.version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct ImagePagePreview: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> CitationImageView {
        let view = CitationImageView(frame: .zero)
        view.open(image)
        return view
    }

    func updateUIView(_ uiView: CitationImageView, context: Context) {
        uiView.open(image)
    }
}

final class CitationImageView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var laidOutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = "资料图片"
        imageView.isAccessibilityElement = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(_ image: UIImage) {
        guard imageView.image !== image else { return }
        let previousSize = imageView.image?.size
        imageView.image = image
        // SwiftUI can reload an equivalent UIImage during a normal view update.
        // Preserve the user's zoom when its source dimensions have not changed.
        guard previousSize != image.size else { return }
        setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        laidOutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        if laidOutSize != bounds.size {
            let relativeZoom = laidOutSize == .zero ? 1 : zoomScale / minimumZoomScale
            laidOutSize = bounds.size
            let fit = min(bounds.width / size.width, bounds.height / size.height)
            minimumZoomScale = fit
            maximumZoomScale = max(1, fit * 6)
            setZoomScale(min(maximumZoomScale, max(fit, fit * relativeZoom)), animated: false)
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

private struct PDFPagePreview: UIViewRepresentable {
    let url: URL
    let pageNumber: Int

    func makeUIView(context: Context) -> CitationPDFView {
        let view = CitationPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        view.open(url: url, pageNumber: pageNumber)
        return view
    }

    func updateUIView(_ uiView: CitationPDFView, context: Context) {
        uiView.open(url: url, pageNumber: pageNumber)
    }
}

final class CitationPDFView: PDFView {
    private var openedURL: URL?
    private var openedPageNumber: Int?
    private var pendingPage: PDFPage?
    private var navigationScheduled = false

    func open(url: URL, pageNumber: Int) {
        guard openedURL != url || openedPageNumber != pageNumber else { return }
        openedURL = url
        openedPageNumber = pageNumber
        document = PDFDocument(url: url)
        pendingPage = document?.page(at: max(0, pageNumber - 1))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFKit can reset a pre-layout go(to:) when the sheet first gets its size.
        guard window != nil, bounds.width > 0, bounds.height > 0,
              pendingPage != nil, !navigationScheduled else { return }
        navigationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.navigationScheduled = false
            guard self.window != nil, self.bounds.width > 0, self.bounds.height > 0,
                  let page = self.pendingPage else { return }
            self.pendingPage = nil
            self.layoutDocumentView()
            self.go(to: page)
        }
    }
}

struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareableFile: Identifiable {
    let id = UUID()
    let url: URL
}
