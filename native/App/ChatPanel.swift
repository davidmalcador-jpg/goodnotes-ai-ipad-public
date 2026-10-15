import SwiftUI

@MainActor
protocol ChatPanelControlling: ObservableObject {
    var isSending: Bool { get }
    var sendingSessionID: UUID? { get }
    var status: String { get }
    var errorMessage: String? { get set }
    func send(question: String, context: ContextSelection, sessionID: UUID?) -> UUID?
    func cancel()
}

extension ChatController: ChatPanelControlling {}

@MainActor
struct ChatPanel<Controller: ChatPanelControlling>: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var controller: Controller
    @Binding var sessionID: UUID?
    @Binding var selectedContext: ContextSelection
    @Binding var includeContext: Bool
    var showCitation: (PageCitation) -> Void
    var showSettings: () -> Void
    var importInstructions = "在 Goodnotes 选择笔记或文件夹, 导出 PDF 后通过分享菜单发送资料. 也可从资料栏导入 PDF、图片或 ZIP."
    @State private var question = ""
    @State private var showContextPicker = false
    @FocusState private var composerFocused: Bool

    private var messages: [ChatMessage] {
        library.sessions.first(where: { $0.id == sessionID })?.messages ?? []
    }

    private var contextTitle: String {
        guard includeContext, selectedContext.kind != .none else { return "本次不附带资料" }
        if selectedContext.kind == .multiple {
            let count = selectedContext.resolvedDocumentIDs(in: library.documents).count
            return "\(selectedContext.collectionIDs.count) 个集合 · \(selectedContext.documentIDs.count) 份单独资料 · 共 \(count) 份"
        }
        if selectedContext.kind == .collection {
            return library.collections.first(where: { $0.id == selectedContext.targetID })?.name ?? "资料集合已移除"
        }
        let title = library.documents.first(where: { $0.id == selectedContext.targetID })?.title ?? "资料已移除"
        if selectedContext.kind == .pages {
            return "\(title) · \(selectedContext.pageNumbers.count) 页"
        }
        return title
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("附带资料", isOn: $includeContext)
                        .toggleStyle(.switch)
                        .fixedSize()
                    Spacer()
                    Button { showContextPicker = true } label: {
                        Label("选择资料", systemImage: "doc.text.magnifyingglass")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("选择上下文资料")
                    .accessibilityIdentifier("chooseContext")
                }
                Button { showContextPicker = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: includeContext ? "paperclip" : "bubble.left")
                        Text(contextTitle).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .font(.subheadline)
                }
                Text("使用导入的资料快照. Goodnotes 中修改或切换笔记后, 请重新分享并更新资料.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)
            Divider()

            ChatMessageList(
                messages: messages,
                sessionID: sessionID,
                isSending: controller.isSending,
                sendingSessionID: controller.sendingSessionID,
                showCitation: showCitation,
                showSettings: showSettings,
                importInstructions: importInstructions
            )
            .id(sessionID)
            if let error = controller.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { controller.errorMessage = nil } label: { Image(systemName: "xmark") }
                }
                .font(.footnote).foregroundStyle(.red).padding()
            }
            if controller.isSending {
                HStack {
                    ProgressView()
                    Text(controller.sendingSessionID == sessionID ? controller.status : "另一对话正在生成…")
                        .font(.caption)
                    Spacer()
                    Button("停止生成") { controller.cancel() }
                        .accessibilityIdentifier("stopGeneration")
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("关于笔记, 你想问什么?", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .accessibilityIdentifier("questionInput")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isSending || library.isImporting)
                .accessibilityLabel("发送问题")
                .accessibilityIdentifier("sendQuestion")
            }
            .padding()
        }
        .onChange(of: library.documents) { _, _ in normalizeSelection() }
        .onChange(of: library.collections) { _, _ in normalizeSelection() }
        .onChange(of: library.isImporting) { _, busy in if !busy { normalizeSelection() } }
        .sheet(isPresented: $showContextPicker) {
            ContextPicker(library: library, selection: $selectedContext, includeContext: $includeContext, isSending: controller.isSending)
        }
    }

    private func normalizeSelection() {
        guard !library.isImporting else { return }
        let value = selectedContext.normalized(documents: library.documents, collections: library.collections)
        if selectedContext != value { selectedContext = value }
        if value.kind == .none { includeContext = false }
    }

    private func send() {
        let effective = includeContext ? selectedContext : .none
        if includeContext && selectedContext.kind == .none {
            showContextPicker = true
            return
        }
        if let id = controller.send(question: question, context: effective, sessionID: sessionID) {
            sessionID = id
            question = ""
            composerFocused = false
        }
    }
}

@MainActor
private struct ChatMessageList: View {
    let messages: [ChatMessage]
    let sessionID: UUID?
    let isSending: Bool
    let sendingSessionID: UUID?
    let showCitation: (PageCitation) -> Void
    let showSettings: () -> Void
    let importInstructions: String
    @State private var scrollTask: Task<Void, Never>?
    @State private var scrollRequestID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Long, growing text needs its actual height before scrolling.
                VStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty {
                        ContentUnavailableView {
                            Label("问问你的笔记", systemImage: "text.bubble")
                        } description: {
                            Text(importInstructions)
                        } actions: {
                            Button("配置模型服务", action: showSettings)
                        }
                        .padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            isGenerating: isSending && sendingSessionID == sessionID && message.id == messages.last?.id,
                            showCitation: showCitation
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .accessibilityIdentifier("chatMessages")
            .background {
                GeometryReader { viewport in
                    Color.clear.onChange(of: viewport.size) { _, _ in requestScroll(proxy) }
                }
            }
            .onAppear { requestScroll(proxy) }
            .onChange(of: messages.last?.id) { _, _ in requestScroll(proxy) }
            .onChange(of: messages.last?.text) { _, _ in requestScroll(proxy) }
            .onChange(of: isSending) { _, _ in requestScroll(proxy) }
            .onDisappear {
                scrollTask?.cancel()
                scrollTask = nil
                scrollRequestID = nil
            }
        }
    }

    private func requestScroll(_ proxy: ScrollViewProxy) {
        // Coalesce streaming deltas into one scroll after layout has caught up.
        guard scrollTask == nil else { return }
        let request = UUID()
        scrollRequestID = request
        scrollTask = Task { @MainActor in
            defer {
                if scrollRequestID == request {
                    scrollTask = nil
                    scrollRequestID = nil
                }
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
            guard !Task.isCancelled, scrollRequestID == request else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isGenerating: Bool
    let showCitation: (PageCitation) -> Void
    @State private var sourcesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.role == .user ? "你" : "AI", systemImage: message.role == .user ? "person.crop.circle" : "sparkles")
                .font(.caption).foregroundStyle(.secondary)
            if message.role == .assistant, let coverage = message.contextCoverage {
                Text(coverage.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chatContextCoverage-\(message.id.uuidString)")
            }
            if message.text.isEmpty {
                Text(isGenerating ? "正在生成…" : "未收到回答")
                    .foregroundStyle(.secondary)
            } else {
                Text(.init(message.text)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chatMessageText-\(message.id.uuidString)")
            }
            if message.interrupted && !isGenerating {
                Label("回答未完成, 已保留收到的内容", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.citations.isEmpty {
                if message.citations.count > 8 {
                    DisclosureGroup(isExpanded: $sourcesExpanded) {
                        citationLinks
                    } label: {
                        Text("本次提供给模型的资料来源（\(message.citations.count) 页）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("chatCitationDisclosure-\(message.id.uuidString)")
                } else {
                    Text("本次提供给模型的资料来源")
                        .font(.caption).foregroundStyle(.secondary)
                    citationLinks
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.09) : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var citationLinks: some View {
        ForEach(message.citations) { citation in
            Button { showCitation(citation) } label: {
                Label("\(citation.documentTitle) · \(citation.pageLabel) · v\(citation.version)", systemImage: citation.sourceIsPDF == false ? "photo" : "doc.text")
                    .font(.caption).multilineTextAlignment(.leading)
            }
            .accessibilityIdentifier("chatCitation-\(message.id.uuidString)-\(citation.id)")
        }
    }
}
