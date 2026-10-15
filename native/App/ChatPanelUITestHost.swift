#if DEBUG && targetEnvironment(simulator)
import SwiftUI

@MainActor
struct ChatPanelUITestHost: View {
    static let launchArgument = "--ui-chat-scroll-regression"
    static let primarySessionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let secondarySessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let oldAssistantID = UUID(uuidString: "11111111-1111-4111-8111-111111111113")!
    static let streamedAssistantID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let sourceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let imageSourceID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

    @StateObject private var library: LibraryStore
    @StateObject private var controller: FixtureChatController
    @State private var sessionID: UUID? = Self.primarySessionID
    @State private var selectedContext = ContextSelection.none
    @State private var includeContext = false
    @State private var shownCitation: PageCitation?

    init() {
        // 每次启动使用独立临时目录, 不读取现有资料或共享收件箱.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatPanelUITest-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let oldAnswer = (1...30).map { index in
                "**历史段落 \(index)**: 这是一段完全合成的旧回答, 用来让聊天内容超过视口高度. 连续更新时, 应始终能看到当前回答和资料来源."
            }.joined(separator: "\n\n")
            let primary = ChatSession(
                id: Self.primarySessionID,
                title: "合成长对话",
                context: .none,
                messages: [
                    ChatMessage(role: .user, text: "合成历史问题"),
                    ChatMessage(id: Self.oldAssistantID, role: .assistant, text: oldAnswer, citations: Self.citations)
                ]
            )
            let secondary = ChatSession(
                id: Self.secondarySessionID,
                title: "合成短对话",
                context: .none,
                messages: [ChatMessage(role: .assistant, text: "另一会话可见标记")]
            )
            let snapshot = LibrarySnapshot(sessions: [primary, secondary])
            try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            fatalError("Unable to prepare synthetic chat UI fixture: \(error)")
        }
        let library = LibraryStore(rootURL: root)
        _library = StateObject(wrappedValue: library)
        _controller = StateObject(wrappedValue: FixtureChatController(library: library))
    }

    static var citations: [PageCitation] {
        [
            PageCitation(documentID: sourceID, documentTitle: "合成资料甲", pageNumber: 1,
                         version: 1, excerpt: "合成引用甲", sourceIsPDF: true),
            PageCitation(documentID: imageSourceID, documentTitle: "合成资料乙", pageNumber: 1,
                         version: 1, excerpt: "合成引用乙", sourceIsPDF: false)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("长对话") { sessionID = Self.primarySessionID }
                    .accessibilityIdentifier("fixtureSessionPrimary")
                Button("另一对话") { sessionID = Self.secondarySessionID }
                    .accessibilityIdentifier("fixtureSessionSecondary")
                Button("新对话") { sessionID = nil }
                    .accessibilityIdentifier("fixtureSessionEmpty")
                Spacer()
                if !library.isImporting {
                    Text("合成资料就绪").font(.caption)
                        .accessibilityIdentifier("fixtureReady")
                }
            }
            .padding(8)
            HStack {
                Button("继续合成片段") { controller.advanceStream() }
                    .accessibilityIdentifier("fixtureAdvanceStream")
                    .disabled(!controller.isAtCheckpoint || controller.checkpoint == 4)
                Button("完成合成回答") { controller.completeStream() }
                    .accessibilityIdentifier("fixtureFinishStream")
                    .disabled(!controller.isAtCheckpoint || controller.checkpoint != 4)
                Text(String(controller.checkpoint))
                    .accessibilityIdentifier("fixtureStreamCheckpoint")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            ChatPanel(
                library: library,
                controller: controller,
                sessionID: $sessionID,
                selectedContext: $selectedContext,
                includeContext: $includeContext,
                showCitation: { shownCitation = $0 },
                showSettings: {}
            )
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.light)
        .sheet(item: $shownCitation) { citation in
            VStack(spacing: 16) {
                Text(citation.documentTitle)
                    .accessibilityIdentifier("fixtureCitationSheet")
                Text(citation.pageLabel)
                Button("关闭合成来源") { shownCitation = nil }
                    .accessibilityIdentifier("fixtureCloseCitation")
            }
            .padding()
        }
        .onDisappear { controller.cancel() }
    }
}

@MainActor
private final class FixtureChatController: ChatPanelControlling {
    @Published var isSending = false
    @Published var sendingSessionID: UUID?
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var checkpoint = 0
    @Published var isAtCheckpoint = false

    private let library: LibraryStore
    private var streamTask: Task<Void, Never>?
    private var generation: UUID?
    private var sendCount = 0
    private var releasedCheckpoint = 0

    init(library: LibraryStore) {
        self.library = library
    }

    @discardableResult
    func send(question: String, context: ContextSelection, sessionID: UUID?) -> UUID? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !library.isImporting, !trimmed.isEmpty else { return nil }
        let id = sessionID ?? library.createSession(context: context)
        sendCount += 1
        let assistantID = sendCount == 1 ? ChatPanelUITestHost.streamedAssistantID : UUID()
        let assistant = ChatMessage(id: assistantID, role: .assistant, text: "",
                                    citations: ChatPanelUITestHost.citations, interrupted: true)
        library.appendMessage(ChatMessage(role: .user, text: trimmed), to: id)
        library.appendMessage(assistant, to: id)
        isSending = true
        sendingSessionID = id
        errorMessage = nil
        checkpoint = 0
        releasedCheckpoint = 0
        isAtCheckpoint = false
        status = "合成流式回答 000/100"
        let currentGeneration = UUID()
        generation = currentGeneration
        streamTask = Task { [weak self] in
            guard let self else { return }
            var message = assistant
            let paragraphs = (1...12).map { index in
                "**合成片段\(index)**: 这段文字用于检验持续增高的回答, 其中没有个人笔记或网络请求. 请检查文字与两个资料来源仍可见."
            }.joined(separator: " ")
            let characters = Array(paragraphs.prefix(461))
            do {
                for index in 1...100 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { return }
                    let end = (characters.count * index + 99) / 100
                    message.text = String(characters.prefix(end))
                    library.updateMessage(message, in: id)
                    status = String(format: "合成流式回答 %03d/100", index)
                    if index.isMultiple(of: 25) {
                        checkpoint = index / 25
                        isAtCheckpoint = true
                        // 测试先检查本批绘制, 再明确放行下一批或最终完成.
                        while releasedCheckpoint < checkpoint {
                            try await Task.sleep(nanoseconds: 20_000_000)
                            try Task.checkCancellation()
                            guard generation == currentGeneration else { return }
                        }
                        isAtCheckpoint = false
                    }
                }
                message.text += "\n\n合成流式回答结束"
                message.interrupted = false
                library.updateMessage(message, in: id)
                finish(currentGeneration)
            } catch {
                // 取消后保留最后一次已经发布的合成片段.
                finish(currentGeneration)
            }
        }
        return id
    }

    func cancel() {
        streamTask?.cancel()
        if let generation { finish(generation) }
    }

    func advanceStream() {
        guard isSending, isAtCheckpoint, checkpoint < 4 else { return }
        releasedCheckpoint = checkpoint
    }

    func completeStream() {
        guard isSending, isAtCheckpoint, checkpoint == 4 else { return }
        releasedCheckpoint = checkpoint
    }

    private func finish(_ completedGeneration: UUID) {
        guard generation == completedGeneration else { return }
        generation = nil
        streamTask = nil
        isSending = false
        sendingSessionID = nil
        status = ""
        isAtCheckpoint = false
    }
}
#endif
