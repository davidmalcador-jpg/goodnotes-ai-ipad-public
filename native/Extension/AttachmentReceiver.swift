import Foundation
import UniformTypeIdentifiers

enum AttachmentError: LocalizedError {
    case empty, unsupported(String), invalidFile, tooLarge, tooManyItems, noRepresentation
    var errorDescription: String? {
        switch self {
        case .empty: return "没有收到文件。请在 Goodnotes 导出 PDF、图片或文件夹 PDF ZIP，再选择问 AI。"
        case .unsupported(let name): return "不支持附件 \(name)。请导出 PDF、PNG、JPEG、HEIC、TIFF 或 ZIP。"
        case .invalidFile: return "附件不是可读取的普通文件，未导入任何文件。"
        case .tooLarge: return "这批附件超过 512 MB，请分批导出。未导入任何文件。"
        case .tooManyItems: return "本次分享的附件数量超过处理上限, 请在 Goodnotes 中分批选择并导出. 未导入任何文件."
        case .noRepresentation: return "分享来源没有提供可读取的文件。请先导出 PDF 到“文件”，再分享。"
        }
    }
}

struct ReceivedBatch: Sendable {
    let directory: URL
    let items: [SharedImportItem]
    var fileURLs: [URL] { items.map { directory.appendingPathComponent($0.relativePath) } }
}

/// Copies each provider's temporary file inside its callback, then commits one manifest.
enum AttachmentReceiver {
    static let maximumBytes = 512 * 1_024 * 1_024
    static let acceptedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "zip"]

    static func safeFilename(_ proposed: String, fallbackExtension: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0\n\r").union(.controlCharacters)
        let cleaned = proposed.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        var name = String(cleaned.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Goodnotes" }
        let suffix = (name as NSString).pathExtension.lowercased()
        if suffix.isEmpty && acceptedExtensions.contains(fallbackExtension.lowercased()) {
            name += "." + fallbackExtension.lowercased()
        }
        guard acceptedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
            throw AttachmentError.unsupported(name)
        }
        return name
    }

    static func receive(_ providers: [NSItemProvider], staging: URL,
                        maximumBytes: Int = AttachmentReceiver.maximumBytes, maximumItems: Int = Int.max,
                        beforeCommit: (@MainActor (ReceivedBatch) -> Void)? = nil) async throws -> ReceivedBatch {
        guard !providers.isEmpty else { throw AttachmentError.empty }
        guard providers.count <= maximumItems else { throw AttachmentError.tooManyItems }
        let batch = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = batch.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var items: [SharedImportItem] = []
        var total = 0
        do {
            for provider in providers {
                try Task.checkCancellation()
                let result = try await copy(provider, to: files, remainingBytes: max(0, maximumBytes - total))
                total += result.size
                items.append(SharedImportItem(filename: result.name, relativePath: "files/" + result.url.lastPathComponent))
            }
            try Task.checkCancellation()
            let received = ReceivedBatch(directory: batch, items: items)
            // The containing app may consume and delete this directory as soon as
            // manifest.json exists. Read any extension previews before publishing it.
            if let beforeCommit { await beforeCommit(received) }
            try Task.checkCancellation()
            try writeManifest(items, batch: batch)
            return received
        } catch {
            try? FileManager.default.removeItem(at: batch)
            if case AttachmentError.tooLarge = error, maximumBytes != Self.maximumBytes {
                throw ImportBudgetError.receivedBytes
            }
            throw error
        }
    }

    static func writeManifest(_ items: [SharedImportItem], batch: URL) throws {
        guard !items.isEmpty else { throw AttachmentError.empty }
        for item in items {
            let candidate = batch.appendingPathComponent(item.relativePath).standardizedFileURL
            guard candidate.path.hasPrefix(batch.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: candidate.path) else { throw AttachmentError.invalidFile }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(items).write(to: batch.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private struct CopiedFile { let url: URL; let name: String; let size: Int }

    /// Serializes temporary-file copying with cancellation and resumes only once.
    private final class ProviderCopyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CopiedFile, Error>?
        private var result: Result<CopiedFile, Error>?
        private var progress: Progress?
        private var isCancelled = false

        func install(_ continuation: CheckedContinuation<CopiedFile, Error>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func setProgress(_ progress: Progress) {
            lock.lock()
            let cancel = isCancelled
            if result == nil { self.progress = progress }
            lock.unlock()
            // Progress cancellation may synchronously invoke the provider callback.
            if cancel { progress.cancel() }
        }

        func copy(_ operation: () throws -> CopiedFile) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            // Keep cancellation from returning while a temporary-file copy runs.
            // After receive() returns, no late callback can copy into its batch.
            let completed = Result { try operation() }
            result = completed
            let continuation = self.continuation
            self.continuation = nil
            progress = nil
            lock.unlock()
            continuation?.resume(with: completed)
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let progress = self.progress
            self.progress = nil
            let continuation: CheckedContinuation<CopiedFile, Error>?
            if result == nil {
                result = .failure(CancellationError())
                continuation = self.continuation
                self.continuation = nil
            } else {
                continuation = nil
            }
            lock.unlock()
            progress?.cancel()
            continuation?.resume(throwing: CancellationError())
        }
    }

    private static func copy(_ provider: NSItemProvider, to directory: URL, remainingBytes: Int) async throws -> CopiedFile {
        let candidates: [UTType] = [.pdf, .image, .zip]
        if let match = candidates.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: match) == true
            } ?? match.identifier
            let gate = ProviderCopyGate()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                        gate.copy {
                            if let error { throw error }
                            guard let url else { throw AttachmentError.noRepresentation }
                            let suffix = UTType(identifier)?.preferredFilenameExtension ?? match.preferredFilenameExtension ?? ""
                            // The provider deletes this URL when the callback returns.
                            return try copyTemporary(url, suggestedName: provider.suggestedName, fallbackExtension: suffix,
                                                     to: directory, remainingBytes: remainingBytes)
                        }
                    }
                    gate.setProgress(progress)
                }
            }, onCancel: { gate.cancel() })
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let gate = ProviderCopyGate()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        gate.copy {
                            if let error { throw error }
                            let url: URL?
                            if let value = item as? URL { url = value }
                            else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                            else { url = nil }
                            guard let url, url.isFileURL else { throw AttachmentError.noRepresentation }
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return try copyTemporary(url, suggestedName: provider.suggestedName, fallbackExtension: url.pathExtension,
                                                     to: directory, remainingBytes: remainingBytes)
                        }
                    }
                }
            }, onCancel: { gate.cancel() })
        }
        // Some file exporters advertise only public.data.
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            let gate = ProviderCopyGate()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard gate.install(continuation) else { return }
                    let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                        gate.copy {
                            if let error { throw error }
                            guard let url else { throw AttachmentError.noRepresentation }
                            return try copyTemporary(url, suggestedName: provider.suggestedName, fallbackExtension: url.pathExtension,
                                                     to: directory, remainingBytes: remainingBytes)
                        }
                    }
                    gate.setProgress(progress)
                }
            }, onCancel: { gate.cancel() })
        }
        throw AttachmentError.unsupported(provider.suggestedName ?? "未知类型")
    }

    private static func copyTemporary(_ source: URL, suggestedName: String?, fallbackExtension: String, to directory: URL, remainingBytes: Int) throws -> CopiedFile {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AttachmentError.invalidFile }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw AttachmentError.invalidFile }
        guard size <= remainingBytes else { throw AttachmentError.tooLarge }
        let name = try safeFilename(suggestedName ?? source.lastPathComponent, fallbackExtension: fallbackExtension)
        let destination = directory.appendingPathComponent(UUID().uuidString + "_" + name)
        try FileManager.default.copyItem(at: source, to: destination)
        // Count the actual copy, not just source metadata that can change during export.
        let copiedSize = (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard copiedSize > 0 else { throw AttachmentError.invalidFile }
        guard copiedSize <= remainingBytes else { throw AttachmentError.tooLarge }
        return CopiedFile(url: destination, name: name, size: copiedSize)
    }
}
