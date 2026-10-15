import Foundation
import Combine

@MainActor
final class ChatController: ObservableObject {
    @Published var isSending = false
    @Published var sendingSessionID: UUID?
    @Published var status = ""
    @Published var errorMessage: String?

    private let library: LibraryStore
    private let settings: SettingsStore
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private static var activeSessions = Set<UUID>()

    init(library: LibraryStore, settings: SettingsStore) {
        self.library = library
        self.settings = settings
    }

    @discardableResult
    func send(question: String, context: ContextSelection, sessionID: UUID?) -> UUID? {
        guard !isSending else { return nil }
        guard !library.isImporting else {
            errorMessage = ChatError.libraryBusy.localizedDescription
            return nil
        }
        if let error = settings.configurationError {
            errorMessage = error
            return nil
        }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return nil }
        let key: String
        do {
            key = try settings.apiKey()
            guard !key.isEmpty else { throw ChatError.missingKey }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let id = sessionID.flatMap { candidate in
            guard let session = library.sessions.first(where: { $0.id == candidate }),
                  canReuse(session: session, context: context),
                  !Self.activeSessions.contains(candidate) else { return nil }
            return candidate
        } ?? library.createSession(context: context)
        guard let sessionIndex = library.sessions.firstIndex(where: { $0.id == id }) else { return nil }
        library.sessions[sessionIndex].context = context
        if library.sessions[sessionIndex].messages.isEmpty {
            library.sessions[sessionIndex].title = String(question.prefix(28))
        }
        let userMessage = ChatMessage(role: .user, text: question)
        library.appendMessage(userMessage, to: id)
        let history = library.sessions.first(where: { $0.id == id })?.messages ?? [userMessage]
        let assistant = ChatMessage(role: .assistant, text: "", interrupted: true)
        library.appendMessage(assistant, to: id)

        isSending = true
        sendingSessionID = id
        status = context.kind == .none ? "正在连接模型…" : "正在读取所选资料…"
        errorMessage = nil
        let responseBuffer = StreamedResponseBuffer()
        let generation = UUID()
        requestID = generation
        Self.activeSessions.insert(id)
        let configuration = settings.configuration
        let documents = library.documents
        let documentURLs = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, library.fileURL(for: $0)) })

        requestTask = Task {
            var prepared = PreparedContext.empty
            defer {
                Self.activeSessions.remove(id)
                if requestID == generation {
                    isSending = false
                    sendingSessionID = nil
                    requestTask = nil
                    requestID = nil
                    status = ""
                }
            }
            do {
                if context.kind != .none {
                    prepared = try await ContextBuilder.prepare(
                        selection: context,
                        documents: documents,
                        question: question,
                        includeImages: configuration.supportsImages,
                        fileURL: { document in documentURLs[document.id]! }
                    )
                }
                try Task.checkCancellation()
                var pending = assistant
                pending.citations = prepared.citations
                pending.contextCoverage = prepared.coverage
                library.updateMessage(pending, in: id)
                status = "正在生成回答…"
                let citations = prepared.citations
                let coverage = prepared.coverage
                let finalText = try await ProviderClient.stream(
                    configuration: configuration,
                    apiKey: key,
                    messages: history,
                    context: prepared,
                    onDelta: { [weak self] delta in
                        responseBuffer.append(delta)
                        Task { @MainActor in
                            self?.receive(text: responseBuffer.text, request: generation, assistant: assistant, citations: citations, coverage: coverage, session: id)
                        }
                    }
                )
                try Task.checkCancellation()
                var completedMessage = assistant
                completedMessage.text = finalText
                completedMessage.citations = prepared.citations
                completedMessage.contextCoverage = prepared.coverage
                completedMessage.interrupted = false
                library.updateMessage(completedMessage, in: id)
            } catch {
                var partial = assistant
                partial.text = responseBuffer.text
                partial.citations = prepared.citations
                partial.contextCoverage = prepared.coverage
                partial.interrupted = true
                library.updateMessage(partial, in: id)
                if error is CancellationError || Task.isCancelled {
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
        return id
    }

    func cancel() {
        requestTask?.cancel()
    }

    func cancelAndWait() async {
        let running = requestTask
        running?.cancel()
        await running?.value
    }

    func canReuse(session: ChatSession, context: ContextSelection) -> Bool {
        guard session.context == context else { return false }
        let sources = session.messages.flatMap(\.citations)
        if context.kind == .none { return sources.isEmpty }
        let selectedIDs = context.resolvedDocumentIDs(in: library.documents)
        return sources.allSatisfy { citation in
            guard selectedIDs.contains(citation.documentID),
                  let document = library.documents.first(where: { $0.id == citation.documentID }),
                  document.version == citation.version else { return false }
            if context.kind == .pages { return context.pageNumbers.contains(citation.pageNumber) }
            return true
        }
    }

    private func receive(text: String, request: UUID, assistant: ChatMessage, citations: [PageCitation], coverage: ContextCoverage?, session: UUID) {
        guard requestID == request, isSending else { return }
        var message = assistant
        message.text = text
        message.citations = citations
        message.contextCoverage = coverage
        library.updateMessage(message, in: session)
    }
}

// 回调先同步保存文本, UI跳转或取消时不会丢失尚未绘制的片段.
private final class StreamedResponseBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        value += text
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum ChatError: LocalizedError {
    case missingKey, libraryBusy
    var errorDescription: String? {
        switch self {
        case .missingKey: return "请在“AI 设置”中保存 API Key 后再提问."
        case .libraryBusy: return "资料正在加载或导入, 请等待完成后再提问."
        }
    }
}
