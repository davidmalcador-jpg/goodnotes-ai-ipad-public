import Foundation
import ZIPFoundation

enum ArchiveImportError: LocalizedError {
    case unsafePath(String)
    case symlink(String)
    case tooLarge
    case tooManyEntries
    case invalidChecksum(String)
    case duplicatePath(String)
    case noDocuments

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "压缩包包含不安全的路径: \(path)"
        case .symlink(let path): return "压缩包包含不支持的链接: \(path)"
        case .tooLarge: return "压缩包解压后的大小超过 1 GB, 请分批导入."
        case .tooManyEntries: return "压缩包超过 5000 个条目, 请分批导入."
        case .invalidChecksum(let path): return "压缩包文件校验失败: \(path)"
        case .duplicatePath(let path): return "压缩包包含重复的文件路径: \(path)"
        case .noDocuments: return "压缩包内没有可导入的 PDF 或图片."
        }
    }
}

enum ArchiveImporter {
    static let maximumExtractedBytes: UInt64 = 1_073_741_824
    static let maximumEntries = 5000

    static func relativePath(of file: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            throw ArchiveImportError.unsafePath(file.lastPathComponent)
        }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    static func safeDestination(relativePath: String, root: URL) throws -> URL {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !components.contains(where: { $0 == ".." || $0 == "." || $0.contains(":") }) else {
            throw ArchiveImportError.unsafePath(relativePath)
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let destination = base.appendingPathComponent(normalized).standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path.hasPrefix(base.path + "/") else {
            throw ArchiveImportError.unsafePath(relativePath)
        }
        return destination
    }

    // 只解包至新目录. 流式统计实际字节, 防止错误的ZIP头绕过预算.
    static func extract(url: URL, destination: URL,
                        maximumBytes: UInt64 = maximumExtractedBytes, maximumEntryCount: Int = maximumEntries) throws -> [URL] {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: destination) } }
        let archive = try Archive(url: url, accessMode: .read)
        var paths = Set<String>()
        var extracted: [URL] = []
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= maximumEntryCount else {
                if maximumEntryCount == maximumEntries { throw ArchiveImportError.tooManyEntries }
                throw ImportBudgetError.archiveEntries
            }
            // Files生成的ZIP可能使用UTF-8文件名却未设置编码标志. 无效UTF-8仍沿用ZIP默认编码.
            let utf8Path = entry.path(using: .utf8)
            let path = utf8Path.isEmpty ? entry.path : utf8Path
            let output = try safeDestination(relativePath: path, root: destination)
            guard paths.insert(output.path.lowercased()).inserted else {
                throw ArchiveImportError.duplicatePath(path)
            }
            switch entry.type {
            case .symlink: throw ArchiveImportError.symlink(path)
            case .directory:
                try manager.createDirectory(at: output, withIntermediateDirectories: true)
            case .file:
                guard entry.uncompressedSize <= maximumBytes - total else {
                    if maximumBytes == maximumExtractedBytes { throw ArchiveImportError.tooLarge }
                    throw ImportBudgetError.extractedBytes
                }
                try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !manager.fileExists(atPath: output.path) else { throw ArchiveImportError.duplicatePath(path) }
                guard manager.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                    try Task.checkCancellation()
                    guard UInt64(chunk.count) <= maximumBytes - total else {
                        if maximumBytes == maximumExtractedBytes { throw ArchiveImportError.tooLarge }
                        throw ImportBudgetError.extractedBytes
                    }
                    total += UInt64(chunk.count)
                    try handle.write(contentsOf: chunk)
                }
                guard checksum == entry.checksum else { throw ArchiveImportError.invalidChecksum(path) }
                extracted.append(output)
            }
        }
        completed = true
        return extracted
    }
}
