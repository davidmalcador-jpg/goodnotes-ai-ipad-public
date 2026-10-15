import Foundation
import Combine
import CryptoKit
import ZIPFoundation

enum LibraryError: LocalizedError {
    case busy
    case missingDocument
    case invalidBackup
    case backupConflict
    case invalidManifest
    case corruptedLibrary

    var errorDescription: String? {
        switch self {
        case .busy: return "正在处理资料, 请等待当前任务完成."
        case .missingDocument: return "资料已不存在."
        case .invalidBackup: return "此文件不是完整的笔记问答备份."
        case .backupConflict: return "备份与当前资料的同一版本内容不同, 已停止恢复以保留现有资料."
        case .invalidManifest: return "共享传入队列损坏, 请从 Goodnotes 重新分享资料."
        case .corruptedLibrary: return "本地资料索引无法读取, 请先恢复备份. 原文件已保留."
        }
    }
}

private struct LibraryImportSource: Sendable {
    var url: URL
    var collectionID: UUID?
    var title: String?
}

private struct LibraryImportResult: Sendable {
    var documents: [NotebookDocument]
    var createdDirectories: [URL]
    var duplicates: Int
}

private actor LibraryDisk {
    let root: URL
    private let importBudget: ImportBudget
    private let beforeSave: (@Sendable (LibrarySnapshot) async -> Void)?
    private var savedRevision: UInt64 = 0
    init(root: URL, importBudget: ImportBudget = .standard, beforeSave: (@Sendable (LibrarySnapshot) async -> Void)? = nil) {
        self.root = root
        self.importBudget = importBudget
        self.beforeSave = beforeSave
    }

    func load() throws -> LibrarySnapshot {
        let manifest = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return LibrarySnapshot() }
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: manifest))
        guard Set(snapshot.documents.map(\.id)).count == snapshot.documents.count else { throw LibraryError.corruptedLibrary }
        for document in snapshot.documents {
            _ = try ArchiveImporter.safeDestination(relativePath: document.relativePath, root: root)
        }
        return snapshot
    }

    func save(_ snapshot: LibrarySnapshot, revision: UInt64) async throws {
        guard revision >= savedRevision else { return }
        await beforeSave?(snapshot)
        try Task.checkCancellation()
        // 异步钩子和actor重入期间可能已有较新写入, 必须再次检查.
        guard revision >= savedRevision else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        savedRevision = revision
    }

    func rollback(_ directories: [URL]) {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
    }

    func importSources(_ sources: [LibraryImportSource], existing: [NotebookDocument]) async throws -> LibraryImportResult {
        let destinationRoot = root
        let budget = importBudget
        let work = Task.detached(priority: .userInitiated) {
            try Self.prepareImports(sources, existing: existing, root: destinationRoot, budget: budget)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func prepareImports(_ sources: [LibraryImportSource], existing: [NotebookDocument],
                                       root: URL, budget: ImportBudget) throws -> LibraryImportResult {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var result = LibraryImportResult(documents: [], createdDirectories: [], duplicates: 0)
        var committed = false
        var documentCount = 0
        var sourceBytes: UInt64 = 0
        var pageCount = 0
        var indexedCharacters = 0
        defer { if !committed { result.createdDirectories.forEach { try? manager.removeItem(at: $0) } } }
        for source in sources {
            try Task.checkCancellation()
            let values = try source.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveImportError.symlink(source.url.lastPathComponent) }
            var extractionRoot: URL?
            defer { if let extractionRoot { try? manager.removeItem(at: extractionRoot) } }
            let files: [URL]
            let base: URL?
            if source.url.pathExtension.lowercased() == "zip" {
                let destination = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                extractionRoot = destination
                files = try ArchiveImporter.extract(url: source.url, destination: destination,
                                                    maximumBytes: budget.maximumExtractedBytes,
                                                    maximumEntryCount: budget.maximumArchiveEntries).filter(DocumentProcessor.supports)
                base = destination
                guard !files.isEmpty else { throw ArchiveImportError.noDocuments }
            } else if values.isDirectory == true {
                files = try supportedFiles(in: source.url, maximumEntries: budget.maximumArchiveEntries)
                base = source.url
                guard !files.isEmpty else { throw ArchiveImportError.noDocuments }
            } else {
                guard DocumentProcessor.supports(source.url) else { throw DocumentProcessingError.unsupportedFormat }
                files = [source.url]
                base = nil
            }
            for file in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard documentCount < budget.maximumDocuments else { throw ImportBudgetError.documents }
                documentCount += 1
                try validateCopyBudget(file, maximumBytes: budget.maximumDocumentBytes)
                let fileBytes = UInt64(max(0, try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                guard fileBytes <= budget.maximumTotalSourceBytes - sourceBytes else { throw ImportBudgetError.totalSourceBytes }
                let id = UUID()
                let relative = "documents/\(id.uuidString)/v1/source.\(file.pathExtension.lowercased())"
                let output = try ArchiveImporter.safeDestination(relativePath: relative, root: root)
                let directory = output.deletingLastPathComponent()
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                result.createdDirectories.append(directory.deletingLastPathComponent())
                try manager.copyItem(at: file, to: output)
                try validateCopyBudget(output, maximumBytes: budget.maximumDocumentBytes)
                let copiedBytes = UInt64(max(0, try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                guard copiedBytes <= budget.maximumTotalSourceBytes - sourceBytes else { throw ImportBudgetError.totalSourceBytes }
                sourceBytes += copiedBytes
                let hash = try contentHash(output)
                if (existing + result.documents).contains(where: { $0.sourceHash == hash && $0.collectionID == source.collectionID }) {
                    try manager.removeItem(at: directory.deletingLastPathComponent())
                    result.createdDirectories.removeLast()
                    result.duplicates += 1
                    continue
                }
                guard pageCount < budget.maximumTotalPages else { throw ImportBudgetError.totalPages }
                let remainingPages = budget.maximumTotalPages - pageCount
                let maximumPages = min(budget.maximumDocumentPages, remainingPages)
                let pages: [NotebookPage]
                do {
                    pages = try DocumentProcessor.processSynchronously(
                        url: output, maximumBytes: budget.maximumDocumentBytes, maximumPages: maximumPages,
                        maximumCharacters: max(0, budget.maximumIndexedCharacters - indexedCharacters))
                } catch ImportBudgetError.documentPages where maximumPages < budget.maximumDocumentPages {
                    throw ImportBudgetError.totalPages
                }
                pageCount += pages.count
                for page in pages { indexedCharacters += page.text.count }
                let title: String
                if let base {
                    title = try ArchiveImporter.relativePath(of: file, root: base)
                } else {
                    title = source.title ?? file.deletingPathExtension().lastPathComponent
                }
                result.documents.append(NotebookDocument(id: id, title: title, relativePath: relative,
                                                          collectionID: source.collectionID, pages: pages, sourceHash: hash))
            }
        }
        try Task.checkCancellation()
        committed = true
        return result
    }

    static func contentHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateCopyBudget(_ file: URL, maximumBytes: Int = 250 * 1024 * 1024) throws {
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumBytes else {
            if maximumBytes == 250 * 1024 * 1024 { throw DocumentProcessingError.tooLarge }
            throw ImportBudgetError.documentBytes
        }
    }

    private static func supportedFiles(in directory: URL, maximumEntries: Int = ArchiveImporter.maximumEntries) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw ArchiveImportError.symlink(file.lastPathComponent) }
            if values.isRegularFile == true && DocumentProcessor.supports(file) { files.append(file) }
            guard files.count <= maximumEntries else {
                if maximumEntries == ArchiveImporter.maximumEntries { throw ArchiveImportError.tooManyEntries }
                throw ImportBudgetError.archiveEntries
            }
        }
        return files
    }

    func update(_ document: NotebookDocument, from source: URL) async throws -> NotebookDocument {
        let destinationRoot = root
        let work = Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard DocumentProcessor.supports(source) else { throw DocumentProcessingError.unsupportedFormat }
            try Self.validateCopyBudget(source)
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            let copied = temporary.appendingPathComponent("source.\(source.pathExtension.lowercased())")
            try manager.copyItem(at: source, to: copied)
            try Self.validateCopyBudget(copied)
            let hash = try Self.contentHash(copied)
            if hash == document.sourceHash { return document }
            let nextVersion = document.version + 1
            let relative = "documents/\(document.id.uuidString)/v\(nextVersion)/source.\(source.pathExtension.lowercased())"
            let output = try ArchiveImporter.safeDestination(relativePath: relative, root: destinationRoot)
            let directory = output.deletingLastPathComponent()
            guard !manager.fileExists(atPath: directory.path) else { throw LibraryError.backupConflict }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var complete = false
            defer { if !complete { try? manager.removeItem(at: directory) } }
            try manager.moveItem(at: copied, to: output)
            let pages = try DocumentProcessor.processSynchronously(url: output)
            try Task.checkCancellation()
            var updated = document
            updated.version = nextVersion
            updated.relativePath = relative
            updated.sourceHash = hash
            updated.importedAt = Date()
            updated.pages = pages
            complete = true
            return updated
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    func exportBackup(_ snapshot: LibrarySnapshot) async throws -> URL {
        let sourceRoot = root
        let progress = Progress(totalUnitCount: 0)
        let work = Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            try JSONEncoder().encode(snapshot).write(to: temporary.appendingPathComponent("library.json"), options: .atomic)
            let documents = sourceRoot.appendingPathComponent("documents")
            if manager.fileExists(atPath: documents.path) {
                try Task.checkCancellation()
                try manager.copyItem(at: documents, to: temporary.appendingPathComponent("documents"))
            }
            try Task.checkCancellation()
            let zip = manager.temporaryDirectory.appendingPathComponent("笔记问答备份-\(UUID().uuidString.prefix(8)).zip")
            do {
                try manager.zipItem(at: temporary, to: zip, shouldKeepParent: false, compressionMethod: .deflate, progress: progress)
                try Task.checkCancellation()
                return zip
            } catch {
                try? manager.removeItem(at: zip)
                throw error
            }
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { progress.cancel(); work.cancel() })
    }

    func restoreBackup(_ source: URL) async throws -> LibrarySnapshot {
        let destinationRoot = root
        let work = Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            let files = try ArchiveImporter.extract(url: source, destination: temporary)
            let manifest = temporary.appendingPathComponent("library.json")
            guard manager.fileExists(atPath: manifest.path) else { throw LibraryError.invalidBackup }
            let imported = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: manifest))
            guard Set(imported.documents.map(\.id)).count == imported.documents.count,
                  Set(imported.sessions.map(\.id)).count == imported.sessions.count,
                  Set(imported.collections.map(\.id)).count == imported.collections.count else { throw LibraryError.invalidBackup }
            for document in imported.documents {
                let expected = "documents/\(document.id.uuidString)/v\(document.version)/source."
                guard document.version > 0, document.relativePath.hasPrefix(expected),
                      document.pages.allSatisfy({ $0.pageNumber > 0 }) else { throw LibraryError.invalidBackup }
                let file = try ArchiveImporter.safeDestination(relativePath: document.relativePath, root: temporary)
                guard manager.fileExists(atPath: file.path), try Self.contentHash(file) == document.sourceHash else {
                    throw LibraryError.invalidBackup
                }
            }
            // 先验证全部冲突, 然后复制. API密钥和设置不在允许恢复的目录中.
            let documentFiles = try files.filter {
                try ArchiveImporter.relativePath(of: $0, root: temporary).hasPrefix("documents/")
            }
            for file in documentFiles {
                try Task.checkCancellation()
                let relative = try ArchiveImporter.relativePath(of: file, root: temporary)
                let destination = try ArchiveImporter.safeDestination(relativePath: relative, root: destinationRoot)
                if manager.fileExists(atPath: destination.path), try Self.contentHash(file) != Self.contentHash(destination) {
                    throw LibraryError.backupConflict
                }
            }
            var createdFiles: [URL] = []
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            var complete = false
            defer { if !complete { createdFiles.forEach { try? manager.removeItem(at: $0) } } }
            for file in documentFiles {
                try Task.checkCancellation()
                let relative = try ArchiveImporter.relativePath(of: file, root: temporary)
                let destination = try ArchiveImporter.safeDestination(relativePath: relative, root: destinationRoot)
                if !manager.fileExists(atPath: destination.path) {
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: file, to: destination)
                    createdFiles.append(destination)
                }
            }
            complete = true
            return imported
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var documents: [NotebookDocument] = []
    @Published var collections: [DocumentCollection] = []
    @Published var sessions: [ChatSession] = []
    @Published var isImporting = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    private let root: URL
    private let disk: LibraryDisk
    private var pendingSave: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var loadFailed = false
    private var revision: UInt64 = 0
    private var isCommittingSnapshot = false
    private var saveAfterCommit = false

    init(rootURL: URL? = nil, importBudget: ImportBudget = .standard,
         beforeDiskSave: (@Sendable (LibrarySnapshot) async -> Void)? = nil) {
        root = rootURL ?? SharedContainer.localRoot()
        disk = LibraryDisk(root: root, importBudget: importBudget, beforeSave: beforeDiskSave)
        isImporting = true
        statusMessage = "正在读取本地资料…"
        loadingTask = Task { [weak self, disk] in
            guard let self else { return }
            do {
                let snapshot = try await disk.load()
                documents = snapshot.documents
                collections = snapshot.collections
                sessions = snapshot.sessions
            } catch {
                loadFailed = true
                errorMessage = LibraryError.corruptedLibrary.localizedDescription
            }
            isImporting = false
            statusMessage = nil
            loadingTask = nil
        }
    }

    private var snapshot: LibrarySnapshot { LibrarySnapshot(documents: documents, collections: collections, sessions: sessions) }

    func save() {
        guard !loadFailed, loadingTask == nil else { return }
        if isCommittingSnapshot {
            saveAfterCommit = true
            return
        }
        pendingSave?.cancel()
        let value = snapshot
        revision += 1
        let writeRevision = revision
        pendingSave = Task { [weak self, disk] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                try Task.checkCancellation()
                try await disk.save(value, revision: writeRevision)
            } catch is CancellationError {} catch { self?.errorMessage = error.localizedDescription }
        }
    }

    /// Extension completion waits for this write instead of losing a debounce.
    func flushSavedState() async throws {
        await loadingTask?.value
        guard !loadFailed else { throw LibraryError.corruptedLibrary }
        while isCommittingSnapshot {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !isImporting else { throw LibraryError.busy }
        while true {
            let pending = pendingSave
            pendingSave = nil
            pending?.cancel()
            await pending?.value
            try Task.checkCancellation()
            revision += 1
            let writeRevision = revision
            try await disk.save(snapshot, revision: writeRevision)
            // A reentrant chat update must also reach disk before completion.
            if revision == writeRevision { return }
        }
    }

    // 发布结构变化前暂存聊天save请求. 提交后补存当前完整状态, 不把新资料写回旧快照.
    private func commit(_ value: LibrarySnapshot, apply: @MainActor () -> Void) async throws {
        isCommittingSnapshot = true
        saveAfterCommit = false
        defer {
            isCommittingSnapshot = false
            if saveAfterCommit { save() }
        }
        let pending = pendingSave
        pendingSave = nil
        pending?.cancel()
        await pending?.value
        revision += 1
        try await disk.save(value, revision: revision)
        apply()
    }

    func importFiles(_ urls: [URL], collectionName: String? = nil) async {
        _ = await performImport(urls, collectionName: collectionName)
    }

    @discardableResult
    private func performImport(_ urls: [URL], collectionName: String? = nil, titles: [URL: String] = [:]) async -> Bool {
        do {
            _ = try await importFilesThrowing(urls, collectionName: collectionName, titles: titles)
            return true
        } catch {
            statusMessage = nil
            errorMessage = error is CancellationError ? "已取消导入, 原资料已保留." : error.localizedDescription
            return false
        }
    }

    /// The extension supplies a fresh collection, never reusing prior shares by name.
    func importSharedFiles(_ urls: [URL], collection: DocumentCollection,
                           titles: [URL: String]) async throws -> [NotebookDocument] {
        do {
            return try await importFilesThrowing(urls, titles: titles, forcedCollection: collection)
        } catch {
            statusMessage = nil
            errorMessage = error is CancellationError ? "已取消导入, 原资料已保留." : error.localizedDescription
            throw error
        }
    }

    private func importFilesThrowing(_ urls: [URL], collectionName: String? = nil,
                                    titles: [URL: String] = [:],
                                    forcedCollection: DocumentCollection? = nil) async throws -> [NotebookDocument] {
        await loadingTask?.value
        try Task.checkCancellation()
        guard !isImporting else { throw LibraryError.busy }
        guard !loadFailed else { throw LibraryError.corruptedLibrary }
        guard !urls.isEmpty else { return [] }
        isImporting = true
        errorMessage = nil
        statusMessage = "正在复制和识别资料…"
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() }; isImporting = false }
        var additions: [DocumentCollection] = []
        let trimmedName = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var namedCollection: UUID? = forcedCollection?.id
        if let forcedCollection {
            guard !collections.contains(where: { $0.id == forcedCollection.id }) else { throw LibraryError.invalidManifest }
            additions.append(forcedCollection)
        } else if let name = trimmedName, !name.isEmpty {
            let collection = collections.first(where: { $0.name == name }) ?? DocumentCollection(name: name)
            namedCollection = collection.id
            if !collections.contains(where: { $0.id == collection.id }) { additions.append(collection) }
        }
        let sources = urls.map { url -> LibraryImportSource in
            var collectionID = namedCollection
            if collectionID == nil && (url.pathExtension.lowercased() == "zip" || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) {
                let collection = DocumentCollection(name: url.deletingPathExtension().lastPathComponent)
                additions.append(collection)
                collectionID = collection.id
            }
            return LibraryImportSource(url: url, collectionID: collectionID, title: titles[url])
        }
        var result: LibraryImportResult?
        do {
            let imported = try await disk.importSources(sources, existing: documents)
            result = imported
            try Task.checkCancellation()
            var next = snapshot
            next.documents += imported.documents
            let used = Set(imported.documents.compactMap(\.collectionID))
            next.collections += additions.filter { used.contains($0.id) }
            try await commit(next) {
                documents += imported.documents
                collections += additions.filter { used.contains($0.id) }
            }
            statusMessage = "已导入 \(imported.documents.count) 份资料" + (imported.duplicates > 0 ? ", 跳过 \(imported.duplicates) 份相同内容." : ".")
            return imported.documents
        } catch {
            if let result { await disk.rollback(result.createdDirectories) }
            throw error
        }
    }

    func consumeSharedImports(inboxURL: URL? = nil) async {
        await loadingTask?.value
        guard !isImporting else { return }
        do {
            let inbox = try inboxURL ?? SharedContainer.stagingDirectory()
            let batches = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for batch in batches.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                let manifest = batch.appendingPathComponent("manifest.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
                let items = try JSONDecoder().decode([SharedImportItem].self, from: Data(contentsOf: manifest))
                guard !items.isEmpty else { throw LibraryError.invalidManifest }
                var urls: [URL] = []
                var titles: [URL: String] = [:]
                for item in items {
                    let url = try ArchiveImporter.safeDestination(relativePath: item.relativePath, root: batch)
                    guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.invalidManifest }
                    urls.append(url)
                    titles[url] = (item.filename as NSString).deletingPathExtension
                }
                if await performImport(urls, titles: titles) { try FileManager.default.removeItem(at: batch) }
                else { return }
            }
        } catch SharedContainerError.notProvisioned {
            // 无共享权限时使用Files手动交接, 启动时不存在共享队列属于正常情况.
            return
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    func updateDocument(_ id: UUID, from url: URL) async {
        await loadingTask?.value
        guard !isImporting else { errorMessage = LibraryError.busy.localizedDescription; return }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return }
        guard let index = documents.firstIndex(where: { $0.id == id }) else { errorMessage = LibraryError.missingDocument.localizedDescription; return }
        isImporting = true
        errorMessage = nil
        statusMessage = "正在更新资料…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() }; isImporting = false }
        let original = documents[index]
        var updated: NotebookDocument?
        do {
            let value = try await disk.update(original, from: url)
            updated = value
            try Task.checkCancellation()
            var next = snapshot
            guard let currentIndex = next.documents.firstIndex(where: { $0.id == id }) else { throw LibraryError.missingDocument }
            next.documents[currentIndex] = value
            try await commit(next) {
                if let current = documents.firstIndex(where: { $0.id == id }) { documents[current] = value }
            }
            statusMessage = value.version == original.version ? "文件内容没有变化." : "已更新为版本 \(value.version), 旧引用仍可查看."
        } catch {
            if let updated, updated.version != original.version {
                await disk.rollback([fileURL(for: updated).deletingLastPathComponent()])
            }
            statusMessage = nil
            errorMessage = error is CancellationError ? "已取消更新, 原资料已保留." : error.localizedDescription
        }
    }

    @discardableResult
    func createCollection(named name: String) -> UUID? {
        guard !isImporting, loadingTask == nil else { errorMessage = LibraryError.busy.localizedDescription; return nil }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入集合名称."; return nil }
        guard !collections.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { errorMessage = "已有同名集合, 请换一个名称."; return nil }
        let collection = DocumentCollection(name: trimmed)
        collections.append(collection)
        errorMessage = nil
        statusMessage = "已新建集合 \(trimmed)."
        save()
        return collection.id
    }

    @discardableResult
    func renameCollection(_ id: UUID, to name: String) -> Bool {
        guard !isImporting, loadingTask == nil else { errorMessage = LibraryError.busy.localizedDescription; return false }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return false }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            errorMessage = "资料集合已不存在."
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "请输入集合名称."; return false }
        guard !collections.contains(where: {
            $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { errorMessage = "已有同名集合, 请换一个名称."; return false }
        errorMessage = nil
        guard collections[index].name != trimmed else { return true }
        collections[index].name = trimmed
        statusMessage = "已重命名集合."
        save()
        return true
    }

    @discardableResult
    func moveDocument(_ id: UUID, toCollection collectionID: UUID?) -> Bool {
        guard !isImporting, loadingTask == nil else { errorMessage = LibraryError.busy.localizedDescription; return false }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return false }
        guard let index = documents.firstIndex(where: { $0.id == id }) else {
            errorMessage = LibraryError.missingDocument.localizedDescription
            return false
        }
        if let collectionID, !collections.contains(where: { $0.id == collectionID }) {
            errorMessage = "目标集合已不存在, 请重新选择."
            return false
        }
        errorMessage = nil
        guard documents[index].collectionID != collectionID else { return true }
        documents[index].collectionID = collectionID
        statusMessage = collectionID == nil ? "已从集合移出, 资料现位于独立资料." : "已移动到所选集合."
        // 归类仅更改集合标识, 不改动资料版本、文件或历史聊天引用.
        save()
        return true
    }

    func deleteDocument(_ id: UUID) {
        guard !isImporting, loadingTask == nil else { errorMessage = LibraryError.busy.localizedDescription; return }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return }
        guard documents.contains(where: { $0.id == id }) else { return }
        documents.removeAll { $0.id == id }
        errorMessage = nil
        statusMessage = "已删除资料, 历史聊天引用仍可查看."
        // 原版本文件保留, 会话中的历史引用仍可打开.
        save()
    }

    func deleteCollection(_ id: UUID, deleteDocuments: Bool) {
        guard !isImporting, loadingTask == nil else { errorMessage = LibraryError.busy.localizedDescription; return }
        guard !loadFailed else { errorMessage = LibraryError.corruptedLibrary.localizedDescription; return }
        guard collections.contains(where: { $0.id == id }) else { return }
        if deleteDocuments {
            documents.removeAll { $0.collectionID == id }
        } else {
            for index in documents.indices where documents[index].collectionID == id {
                documents[index].collectionID = nil
            }
        }
        collections.removeAll { $0.id == id }
        errorMessage = nil
        statusMessage = deleteDocuments ? "已删除集合及资料, 历史聊天引用仍可查看." : "已解散集合, 资料已移到独立资料."
        // 删除仅更新资料索引, 保留源文件和历史聊天中的版本引用.
        save()
    }

    func createSession(context: ContextSelection) -> UUID {
        let session = ChatSession(title: "新对话", context: context)
        sessions.insert(session, at: 0)
        save()
        return session.id
    }

    func appendMessage(_ message: ChatMessage, to id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].messages.append(message)
        if sessions[index].title == "新对话" && message.role == .user { sessions[index].title = String(message.text.prefix(30)) }
        save()
    }

    func updateMessage(_ message: ChatMessage, in id: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == id }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id }) else { return }
        sessions[sessionIndex].messages[messageIndex] = message
        save()
    }

    func fileURL(for document: NotebookDocument) -> URL {
        (try? ArchiveImporter.safeDestination(relativePath: document.relativePath, root: root)) ?? root.appendingPathComponent("invalid-document")
    }

    func fileURL(for citation: PageCitation) -> URL? {
        if let document = documents.first(where: { $0.id == citation.documentID && $0.version == citation.version }) {
            let url = fileURL(for: document)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let directory = root.appendingPathComponent("documents/\(citation.documentID.uuidString)/v\(citation.version)")
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("source.") && DocumentProcessor.supports($0) })
    }

    func exportBackup() async throws -> URL {
        await loadingTask?.value
        guard !isImporting else { throw LibraryError.busy }
        guard !loadFailed else { throw LibraryError.corruptedLibrary }
        isImporting = true
        statusMessage = "正在生成资料和聊天备份…"
        defer { isImporting = false; statusMessage = nil }
        return try await disk.exportBackup(snapshot)
    }

    func importBackup(_ url: URL) async {
        await loadingTask?.value
        guard !isImporting else { errorMessage = LibraryError.busy.localizedDescription; return }
        isImporting = true
        errorMessage = nil
        statusMessage = "正在合并恢复备份…"
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() }; isImporting = false }
        do {
            let imported = try await disk.restoreBackup(url)
            var next = snapshot
            let documentIDs = Set(documents.map(\.id))
            let collectionIDs = Set(collections.map(\.id))
            let sessionIDs = Set(sessions.map(\.id))
            next.documents += imported.documents.filter { !documentIDs.contains($0.id) }
            next.collections += imported.collections.filter { !collectionIDs.contains($0.id) }
            next.sessions += imported.sessions.filter { !sessionIDs.contains($0.id) }
            try await commit(next) {
                let liveDocumentIDs = Set(documents.map(\.id))
                let liveCollectionIDs = Set(collections.map(\.id))
                let liveSessionIDs = Set(sessions.map(\.id))
                documents += imported.documents.filter { !liveDocumentIDs.contains($0.id) }
                collections += imported.collections.filter { !liveCollectionIDs.contains($0.id) }
                sessions += imported.sessions.filter { !liveSessionIDs.contains($0.id) }
                loadFailed = false
            }
            statusMessage = "备份已合并恢复, 当前资料已保留."
        } catch {
            statusMessage = nil
            errorMessage = error is CancellationError ? "已取消恢复." : error.localizedDescription
        }
    }
}
