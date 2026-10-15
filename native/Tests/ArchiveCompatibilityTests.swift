import XCTest
import UIKit
import ZIPFoundation
@testable import NoteAssistant

final class ArchiveCompatibilityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // 修改正常ZIP的编码标志和同长度文件名, 内容及CRC保持原样.
    private func removeUTF8Flags(at url: URL, replacementNames: [String: Data] = [:]) throws {
        var bytes = try Data(contentsOf: url)
        func integer(at offset: Int, count: Int) -> UInt32 {
            (0..<count).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << (8 * $1)) }
        }
        guard bytes.count >= 22, integer(at: bytes.count - 22, count: 4) == 0x06054b50 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let entries = Int(integer(at: bytes.count - 12, count: 2))
        var offset = Int(integer(at: bytes.count - 6, count: 4))
        for _ in 0..<entries {
            guard offset + 46 <= bytes.count, integer(at: offset, count: 4) == 0x02014b50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let nameLength = Int(integer(at: offset + 28, count: 2))
            let extraLength = Int(integer(at: offset + 30, count: 2))
            let commentLength = Int(integer(at: offset + 32, count: 2))
            let local = Int(integer(at: offset + 42, count: 4))
            guard offset + 46 + nameLength + extraLength + commentLength <= bytes.count,
                  local + 30 + nameLength <= bytes.count,
                  integer(at: local, count: 4) == 0x04034b50 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = String(data: bytes.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8) ?? ""
            bytes[offset + 9] &= 0xf7
            bytes[local + 7] &= 0xf7
            if let replacement = replacementNames[name] {
                guard replacement.count == nameLength else { throw CocoaError(.fileReadCorruptFile) }
                bytes.replaceSubrange(offset + 46..<offset + 46 + nameLength, with: replacement)
                bytes.replaceSubrange(local + 30..<local + 30 + nameLength, with: replacement)
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        try bytes.write(to: url)
    }

    @MainActor
    func testFilesZIPWithoutUTF8FlagKeepsChineseDocumentTitle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("source.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 500, height: 700))
        try renderer.pdfData { context in
            context.beginPage()
            ("Synthetic circuit notes describe mesh currents and voltage laws in enough detail for PDF extraction." as NSString)
                .draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }.write(to: pdf)
        let zip = root.appendingPathComponent("课程资料.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "章节/草稿.pdf", fileURL: pdf)
        }
        try removeUTF8Flags(at: zip)
        let store = LibraryStore(rootURL: root.appendingPathComponent("library"))
        await store.importFiles([zip])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.map(\.title), ["章节/草稿.pdf"])
        XCTAssertEqual(store.documents.first?.pages.count, 1)
        XCTAssertEqual(store.collections.first?.name, "课程资料")
    }

    func testLegacyCP437NameFallsBackWhenUTF8IsInvalid() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt")
        let content = Data("Legacy archive content".utf8)
        try content.write(to: source)
        let zip = root.appendingPathComponent("legacy.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "cafe.txt", fileURL: source)
        }
        try removeUTF8Flags(at: zip, replacementNames: ["cafe.txt": Data([0x63, 0x61, 0x66, 0x82, 0x2e, 0x74, 0x78, 0x74])])
        let files = try ArchiveImporter.extract(url: zip, destination: root.appendingPathComponent("extracted"))
        XCTAssertEqual(files.map(\.lastPathComponent), ["café.txt"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), content)
    }

    func testRelativePathsSurviveCanonicalTemporaryDirectoryAlias() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("temporary-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let source = root.appendingPathComponent("fixture.txt")
        try Data("Alias fixture".utf8).write(to: source)
        let zip = root.appendingPathComponent("alias.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "documents/chapter/source.txt", fileURL: source)
        }
        let extractionRoot = alias.appendingPathComponent("extracted")
        let files = try ArchiveImporter.extract(url: zip, destination: extractionRoot)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(try ArchiveImporter.relativePath(of: file, root: extractionRoot), "documents/chapter/source.txt")
        XCTAssertEqual(try ArchiveImporter.relativePath(of: extractionRoot.appendingPathComponent("documents/chapter/source.txt"),
                                                       root: actual.appendingPathComponent("extracted")), "documents/chapter/source.txt")
        XCTAssertThrowsError(try ArchiveImporter.relativePath(of: root.appendingPathComponent("outside.txt"), root: extractionRoot))
        XCTAssertThrowsError(try ArchiveImporter.relativePath(of: actual.appendingPathComponent("extracted-other/source.txt"), root: extractionRoot))
    }
}
