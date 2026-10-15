import Foundation

struct ProviderConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var supportsImages: Bool
    static let deepSeek = Self(baseURL: "https://api.deepseek.com", model: "deepseek-flash", supportsImages: true)
    static let deepSeekPro = Self(baseURL: "https://api.deepseek.com", model: "deepseek-v4-pro", supportsImages: false)
}

struct NotebookPage: Codable, Equatable, Sendable {
    var pageNumber: Int
    var text: String
}

struct NotebookDocument: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var relativePath: String
    var collectionID: UUID?
    var importedAt: Date = Date()
    var version: Int = 1
    var pages: [NotebookPage]
    var sourceHash: String
}

struct DocumentCollection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
}

enum ContextKind: String, Codable, Sendable { case none, document, collection, pages, multiple }
struct ContextSelection: Codable, Equatable, Sendable {
    var kind: ContextKind
    var targetID: UUID?
    var pageNumbers: [Int]
    var documentIDs: [UUID]
    var collectionIDs: [UUID]
    static let none = Self(kind: .none, targetID: nil)

    init(kind: ContextKind, targetID: UUID? = nil, pageNumbers: [Int] = [],
         documentIDs: [UUID] = [], collectionIDs: [UUID] = []) {
        self.kind = kind
        self.targetID = targetID
        self.pageNumbers = pageNumbers
        self.documentIDs = Set(documentIDs).sorted { $0.uuidString < $1.uuidString }
        self.collectionIDs = Set(collectionIDs).sorted { $0.uuidString < $1.uuidString }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, targetID, pageNumbers, documentIDs, collectionIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(ContextKind.self, forKey: .kind),
                  targetID: try values.decodeIfPresent(UUID.self, forKey: .targetID),
                  pageNumbers: try values.decodeIfPresent([Int].self, forKey: .pageNumbers) ?? [],
                  documentIDs: try values.decodeIfPresent([UUID].self, forKey: .documentIDs) ?? [],
                  collectionIDs: try values.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? [])
    }

    func resolvedDocumentIDs(in documents: [NotebookDocument]) -> Set<UUID> {
        switch kind {
        case .none:
            return []
        case .document, .pages:
            guard let targetID, documents.contains(where: { $0.id == targetID }) else { return [] }
            return [targetID]
        case .collection:
            guard let targetID else { return [] }
            return Set(documents.filter { $0.collectionID == targetID }.map(\.id))
        case .multiple:
            let selectedDocuments = Set(documentIDs)
            let selectedCollections = Set(collectionIDs)
            return Set(documents.filter { document in
                selectedDocuments.contains(document.id) || document.collectionID.map { selectedCollections.contains($0) } == true
            }.map(\.id))
        }
    }

    func normalized(documents: [NotebookDocument], collections: [DocumentCollection]) -> ContextSelection {
        let validDocuments = Set(documents.map(\.id))
        let validCollections = Set(collections.map(\.id))
        switch kind {
        case .none:
            return .none
        case .document, .pages:
            guard let targetID, validDocuments.contains(targetID) else { return .none }
            return Self(kind: kind, targetID: targetID, pageNumbers: pageNumbers)
        case .collection:
            guard let targetID, validCollections.contains(targetID) else { return .none }
            return Self(kind: .collection, targetID: targetID)
        case .multiple:
            let remainingDocuments = documentIDs.filter { validDocuments.contains($0) }
            let remainingCollections = collectionIDs.filter { validCollections.contains($0) }
            guard !remainingDocuments.isEmpty || !remainingCollections.isEmpty else { return .none }
            return Self(kind: .multiple, documentIDs: remainingDocuments, collectionIDs: remainingCollections)
        }
    }
}

struct PageCitation: Codable, Identifiable, Equatable, Sendable {
    var documentID: UUID
    var documentTitle: String
    var pageNumber: Int
    var version: Int
    var excerpt: String
    var sourceIsPDF: Bool? = nil
    var pageLabel: String { sourceIsPDF == false ? "图片 第 \(pageNumber) 页" : "PDF 第 \(pageNumber) 页" }
    var id: String { "\(documentID.uuidString)-\(version)-\(pageNumber)" }
}

enum ChatRole: String, Codable, Sendable { case user, assistant, system }
struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var role: ChatRole
    var text: String
    var createdAt: Date = Date()
    var citations: [PageCitation] = []
    var interrupted: Bool = false
    var contextCoverage: ContextCoverage? = nil
}

struct ChatSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var context: ContextSelection
    var messages: [ChatMessage] = []
}

struct ImageAttachment: Sendable { var data: Data; var mimeType: String }
struct ContextCoverage: Codable, Equatable, Sendable {
    var selectedPageCount: Int
    var readablePageCount: Int
    var sentTextPageCount: Int
    var sentImagePageCount: Int

    var summary: String {
        var value = "本次附带完整文字 \(sentTextPageCount)/\(selectedPageCount) 页"
        if sentImagePageCount > 0 { value += ", 页图 \(sentImagePageCount) 张" }
        let unreadable = max(0, selectedPageCount - readablePageCount)
        if unreadable > 0 { value += "; \(unreadable) 页未提取到文字" }
        return value
    }
}
struct PreparedContext: Sendable {
    var text: String
    var citations: [PageCitation]
    var images: [ImageAttachment]
    var coverage: ContextCoverage? = nil
    static let empty = Self(text: "", citations: [], images: [])
}

struct LibrarySnapshot: Codable, Sendable {
    var documents: [NotebookDocument] = []
    var collections: [DocumentCollection] = []
    var sessions: [ChatSession] = []
}

struct SharedImportItem: Codable, Sendable {
    var id: UUID = UUID()
    var filename: String
    var relativePath: String
    var createdAt: Date = Date()
}

enum AttachmentExportResult: Equatable, Sendable {
    case saved
    case cancelled
    case unconfirmed
}

struct AttachmentExportState: Sendable {
    private(set) var attemptID: UUID?
    private(set) var result: AttachmentExportResult?
    private(set) var isPresented = false

    mutating func begin() -> UUID? {
        // A delegate result can arrive before the sheet finishes dismissing.
        guard !isPresented else { return nil }
        let id = UUID()
        attemptID = id
        result = nil
        isPresented = true
        return id
    }

    @discardableResult
    mutating func complete(_ result: AttachmentExportResult, attemptID: UUID) -> Bool {
        guard self.attemptID == attemptID else { return false }
        // Dismissal is provisional. An explicit delegate result remains authoritative.
        guard self.result == nil || self.result == .unconfirmed else { return false }
        guard self.result != result else { return false }
        self.result = result
        return true
    }

    @discardableResult
    mutating func dismiss() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        guard result == nil else { return false }
        result = .unconfirmed
        return true
    }
}
