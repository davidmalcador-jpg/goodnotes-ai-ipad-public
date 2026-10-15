import Foundation
import SwiftUI
import UIKit

enum AttachmentExport {
    // 仅用于扩展私有批次. 文件复制使用磁盘操作, 不把整份附件读进Data.
    static func prepareFiles(from batch: ReceivedBatch) async throws -> [URL] {
        let directory = batch.directory.appendingPathComponent("export", isDirectory: true)
        let names = batch.items.map(\.filename)
        let sources = batch.fileURLs
        let work = Task.detached(priority: .userInitiated) {
            try prepareSynchronously(directory: directory, names: names, sources: sources)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func prepareSynchronously(directory: URL, names: [String], sources: [URL]) throws -> [URL] {
        try Task.checkCancellation()
        // 接收批次已经存在. 不重建父目录, 避免finish后异步工作重建已清理的批次.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var usedNames = Set<String>()
        var urls: [URL] = []
        for (originalName, source) in zip(names, sources) {
            try Task.checkCancellation()
            let name = try AttachmentReceiver.safeFilename(originalName, fallbackExtension: source.pathExtension)
            let stem = (name as NSString).deletingPathExtension
            let suffix = (name as NSString).pathExtension
            var filename = name
            var occurrence = 2
            while usedNames.contains(filename.precomposedStringWithCanonicalMapping.lowercased()) {
                filename = "\(stem) (\(occurrence)).\(suffix)"
                occurrence += 1
            }
            usedNames.insert(filename.precomposedStringWithCanonicalMapping.lowercased())
            let destination = directory.appendingPathComponent(filename)
            try FileManager.default.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            urls.append(destination)
        }
        guard !urls.isEmpty else { throw AttachmentError.empty }
        try Task.checkCancellation()
        return urls
    }
}

struct AttachmentFileExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: (AttachmentExportResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (AttachmentExportResult) -> Void
        init(completion: @escaping (AttachmentExportResult) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.isEmpty ? .unconfirmed : .saved)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.cancelled)
        }
    }
}
