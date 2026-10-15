import Foundation

/// Disk and index budgets. The main app keeps its existing per-file limits.
struct ImportBudget: Sendable, Equatable {
    var maximumDocumentBytes = 250 * 1024 * 1024
    var maximumDocumentPages = 2000
    var maximumExtractedBytes: UInt64 = 1_073_741_824
    var maximumArchiveEntries = 5000
    var maximumDocuments = Int.max
    var maximumTotalSourceBytes: UInt64 = UInt64.max
    var maximumTotalPages = Int.max
    var maximumIndexedCharacters = Int.max
    var maximumReceivedBytes = 512 * 1024 * 1024
    var maximumReceivedItems = Int.max

    static let standard = Self()
    static let shareExtension = Self(
        maximumDocumentBytes: 64 * 1024 * 1024,
        maximumDocumentPages: Int.max,
        maximumExtractedBytes: 128 * 1024 * 1024,
        maximumArchiveEntries: 500,
        maximumDocuments: 100,
        maximumTotalSourceBytes: 128 * 1024 * 1024,
        maximumTotalPages: Int.max,
        maximumIndexedCharacters: Int.max,
        maximumReceivedBytes: 64 * 1024 * 1024,
        maximumReceivedItems: 100
    )
}

enum ImportBudgetError: LocalizedError, Equatable {
    case documentBytes, documentPages, extractedBytes, archiveEntries
    case documents, totalSourceBytes, totalPages, indexedCharacters, receivedBytes

    var errorDescription: String? {
        let reason: String
        switch self {
        case .documentBytes: reason = "单份资料大小"
        case .documentPages: reason = "单份资料页数"
        case .extractedBytes: reason = "ZIP 解压大小"
        case .archiveEntries: reason = "ZIP 条目数"
        case .documents: reason = "资料数量"
        case .totalSourceBytes: reason = "本批资料总大小"
        case .totalPages: reason = "本批资料总页数"
        case .indexedCharacters: reason = "本批识别文字量"
        case .receivedBytes: reason = "本次分享附件总大小"
        }
        return "\(reason)超过本次处理上限, 未导入本批资料. 请在 Goodnotes 中分批选择并导出."
    }
}

enum DirectShareImportError: LocalizedError {
    case empty
    var errorDescription: String? { "本次分享没有可读取的 PDF 或图片. 请在 Goodnotes 导出 PDF、图片或 PDF 文件夹 ZIP 后选择问 AI." }
}

enum DirectShareImport {
    /// Only the newly received batch becomes context. Prior shares stay outside it.
    @MainActor
    static func importBatch(_ batch: ReceivedBatch, into library: LibraryStore) async throws -> ContextSelection {
        try Task.checkCancellation()
        guard !batch.items.isEmpty else { throw DirectShareImportError.empty }
        var urls: [URL] = []
        var titles: [URL: String] = [:]
        for item in batch.items {
            let url = try ArchiveImporter.safeDestination(relativePath: item.relativePath, root: batch.directory)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AttachmentError.invalidFile }
            urls.append(url)
            titles[url] = (item.filename as NSString).deletingPathExtension
        }
        let proposed = batch.items.count == 1 ? titles[urls[0]] ?? "本次分享" : "本次分享"
        let collection = DocumentCollection(name: "\(proposed) · \(UUID().uuidString.prefix(8))")
        let imported = try await library.importSharedFiles(urls, collection: collection, titles: titles)
        guard !imported.isEmpty else { throw DirectShareImportError.empty }
        if imported.count == 1 {
            return ContextSelection(kind: .document, targetID: imported[0].id)
        }
        return ContextSelection(kind: .collection, targetID: collection.id)
    }
}
