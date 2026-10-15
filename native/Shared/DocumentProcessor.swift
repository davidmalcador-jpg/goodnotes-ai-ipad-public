import Foundation
import PDFKit
import Vision
import UIKit
import ImageIO

enum DocumentProcessingError: LocalizedError {
    case unsupportedFormat
    case unreadablePDF
    case lockedPDF
    case emptyDocument
    case tooLarge
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "仅支持 PDF、PNG、JPEG、HEIC、TIFF 和图片. Goodnotes 文件请先导出为 PDF."
        case .unreadablePDF: return "无法读取 PDF, 请检查文件是否完整."
        case .lockedPDF: return "PDF 已加密, 请先导出未加密的副本."
        case .emptyDocument: return "文件没有可读取的页面."
        case .tooLarge: return "文件超过 250 MB 或 2000 页, 请分批导入."
        case .unreadableImage: return "无法读取这张图片."
        }
    }
}

enum DocumentProcessor {
    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"]

    static func supports(_ url: URL) -> Bool {
        // Files/macOS ZIPs can include AppleDouble sidecars with a document suffix.
        // These contain metadata, not the PDF/image bytes they appear to name.
        guard !url.pathComponents.contains("__MACOSX"),
              !url.lastPathComponent.hasPrefix("._") else { return false }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func process(url: URL, maximumBytes: Int = 250 * 1024 * 1024,
                        maximumPages: Int = 2000, maximumCharacters: Int = Int.max) async throws -> [NotebookPage] {
        let work = Task.detached(priority: .userInitiated) {
            try processSynchronously(url: url, maximumBytes: maximumBytes,
                                     maximumPages: maximumPages, maximumCharacters: maximumCharacters)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    static func processSynchronously(url: URL, maximumBytes: Int = 250 * 1024 * 1024,
                                     maximumPages: Int = 2000, maximumCharacters: Int = Int.max) throws -> [NotebookPage] {
        try Task.checkCancellation()
        guard supports(url) else { throw DocumentProcessingError.unsupportedFormat }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumBytes else {
            if maximumBytes == 250 * 1024 * 1024 { throw DocumentProcessingError.tooLarge }
            throw ImportBudgetError.documentBytes
        }
        if url.pathExtension.lowercased() != "pdf" {
            guard maximumPages >= 1 else { throw ImportBudgetError.totalPages }
            let text = try autoreleasepool { try recognize(image: downsampledImage(url: url)) }
            guard text.count <= maximumCharacters else { throw ImportBudgetError.indexedCharacters }
            return [NotebookPage(pageNumber: 1, text: text)]
        }
        guard let document = PDFDocument(url: url) else { throw DocumentProcessingError.unreadablePDF }
        guard !document.isLocked else { throw DocumentProcessingError.lockedPDF }
        guard document.pageCount > 0 else { throw DocumentProcessingError.emptyDocument }
        guard document.pageCount <= maximumPages else {
            if maximumPages == 2000 { throw DocumentProcessingError.tooLarge }
            throw ImportBudgetError.documentPages
        }
        var pages: [NotebookPage] = []
        var characters = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let result: NotebookPage = try autoreleasepool {
                guard let page = document.page(at: index) else { throw DocumentProcessingError.unreadablePDF }
                var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count < 40 {
                    let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                    if let cgImage = image.cgImage {
                        let recognized = try recognize(image: cgImage)
                        if recognized.count > text.count { text = recognized }
                    }
                }
                return NotebookPage(pageNumber: index + 1, text: text)
            }
            guard result.text.count <= max(0, maximumCharacters - characters) else { throw ImportBudgetError.indexedCharacters }
            characters += result.text.count
            pages.append(result)
        }
        return pages
    }

    static func downsampledImage(url: URL, maximumDimension: Int = 1600) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DocumentProcessingError.unreadableImage }
        return image
    }

    static func recognize(image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func pageImage(url: URL, pageNumber: Int) throws -> ImageAttachment {
        try Task.checkCancellation()
        let image: UIImage
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked,
                  let page = pdf.page(at: pageNumber - 1) else { throw DocumentProcessingError.unreadablePDF }
            image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
        } else {
            guard pageNumber == 1 else { throw DocumentProcessingError.emptyDocument }
            image = UIImage(cgImage: try downsampledImage(url: url))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { throw DocumentProcessingError.unreadableImage }
        return ImageAttachment(data: data, mimeType: "image/jpeg")
    }
}
