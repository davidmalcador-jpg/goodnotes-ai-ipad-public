import UIKit
import SwiftUI

@MainActor
final class ActionModel: ObservableObject {
    let library: LibraryStore
    let settings: SettingsStore
    let controller: ChatController
    @Published var status = "正在接收 Goodnotes 分享的资料…"
    @Published var errorMessage: String?
    @Published var filenames: [String] = []
    @Published var selection = ContextSelection.none
    @Published var isReceiving = true
    @Published var isReady = false
    @Published var isFinishing = false
    @Published var exportURLs: [URL] = []
    @Published var isExporting = false
    @Published var showFileExporter = false
    private var receiveTask: Task<Void, Never>?
    private var privateStaging: URL?
    private var receiveID: UUID?
    private var isFinished = false
    private let prepareExport: @Sendable (ReceivedBatch) async throws -> [URL]
    private var fileExportState = AttachmentExportState()
    var fileExportAttemptID: UUID? { fileExportState.attemptID }

    init(rootURL: URL? = nil,
         prepareExport: @escaping @Sendable (ReceivedBatch) async throws -> [URL] = { try await AttachmentExport.prepareFiles(from: $0) }) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AskAI", isDirectory: true)
        let library = LibraryStore(rootURL: root, importBudget: .shareExtension)
        let settings = SettingsStore(rootURL: root, credentialScope: .extensionPrivate, isShareExtension: true)
        self.library = library
        self.settings = settings
        self.controller = ChatController(library: library, settings: settings)
        self.prepareExport = prepareExport
    }

    func receive(_ providers: [NSItemProvider]) {
        guard receiveTask == nil, !isFinished, !isFinishing else { return }
        let generation = UUID()
        receiveID = generation
        receiveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isReceiving = false; self.receiveTask = nil }
            do {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NoteAssistant-export-\(UUID().uuidString)", isDirectory: true)
                self.privateStaging = staging
                let budget = ImportBudget.shareExtension
                let batch = try await AttachmentReceiver.receive(providers, staging: staging,
                    maximumBytes: budget.maximumReceivedBytes, maximumItems: budget.maximumReceivedItems)
                try Task.checkCancellation()
                guard self.receiveID == generation, !self.isFinished else { return }
                self.filenames = batch.items.map(\.filename)
                self.status = "正在本机读取 PDF、识别图片和整理文件夹…"
                let selection = try await DirectShareImport.importBatch(batch, into: self.library)
                try Task.checkCancellation()
                guard self.receiveID == generation, !self.isFinished else { return }
                self.selection = selection
                self.isReady = true
                self.status = "资料已就绪，可直接提问。无需保存到“文件”或转存。"
                do { self.exportURLs = try await self.prepareExport(batch) }
                catch is CancellationError { throw CancellationError() }
                catch { self.errorMessage = "资料已可问答，但另存副本暂不可用。" }
            } catch is CancellationError {
                self.status = "已停止读取，已有资料保留。"
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "本次分享未完成，请在 Goodnotes 重新选择或分批分享。"
            }
        }
    }

    func beginFileExport() {
        guard !isReceiving, !isExporting, !isFinished, !exportURLs.isEmpty,
              fileExportState.begin() != nil else { return }
        errorMessage = nil
        isExporting = true
        showFileExporter = true
    }

    func fileExportCompleted(_ result: AttachmentExportResult, attemptID: UUID) {
        guard !isFinished, fileExportState.complete(result, attemptID: attemptID) else { return }
        isExporting = fileExportState.isPresented
        showFileExporter = false
        switch result {
        case .saved: status = "副本已保存。可继续在这里提问。"
        case .cancelled: status = "已取消保存副本，直接问答不受影响。"
        case .unconfirmed: status = "副本保存结果尚未确认，直接问答不受影响。"
        }
    }

    func fileExporterDismissed() {
        guard !isFinished else { return }
        if fileExportState.dismiss() { status = "副本保存结果尚未确认，直接问答不受影响。" }
        isExporting = fileExportState.isPresented
    }

    func cancel() {
        receiveTask?.cancel()
        controller.cancel()
    }

    func finish() async -> Bool {
        guard !isExporting, !isFinishing, !isFinished else { return false }
        isFinishing = true
        let receiving = receiveTask
        receiving?.cancel()
        await receiving?.value
        await controller.cancelAndWait()
        do { try await library.flushSavedState() }
        catch {
            errorMessage = "聊天保存失败，请稍后再点完成。\(error.localizedDescription)"
            isFinishing = false
            return false
        }
        isFinished = true
        receiveID = nil
        cleanPrivateStaging()
        return true
    }

    private func cleanPrivateStaging() {
        guard let directory = privateStaging else { return }
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let candidate = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == temporary,
              candidate.lastPathComponent.hasPrefix("NoteAssistant-export-") else { return }
        try? FileManager.default.removeItem(at: candidate)
        privateStaging = nil
        exportURLs = []
    }
}

@MainActor
struct ActionContentView: View {
    @ObservedObject var model: ActionModel
    let finish: () -> Void
    var body: some View {
        DirectShareChatView(model: model, library: model.library, controller: model.controller,
                            settings: model.settings, finish: finish)
    }
}

@MainActor
private struct DirectShareChatView: View {
    @ObservedObject var model: ActionModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var controller: ChatController
    @ObservedObject var settings: SettingsStore
    let finish: () -> Void
    @State private var sessionID: UUID?
    @State private var includeContext = true
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var preview: DocumentPreviewRequest?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        if model.isReceiving { ProgressView() }
                        Text(model.status).font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("directShareStatus")
                        Spacer(minLength: 0)
                        if model.isReady {
                            Button("新对话") { controller.cancel(); sessionID = nil }
                                .accessibilityIdentifier("newDirectShareConversation")
                        }
                    }
                    if !model.filenames.isEmpty {
                        Text(model.filenames.joined(separator: " · ")).font(.caption).lineLimit(2)
                            .accessibilityIdentifier("directShareAttachments")
                    }
                    if let error = model.errorMessage ?? library.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding().background(.bar)
                if model.isReady {
                    ChatPanel(library: library, controller: controller, sessionID: $sessionID,
                              selectedContext: $model.selection, includeContext: $includeContext,
                              showCitation: showCitation, showSettings: { showSettings = true },
                              importInstructions: "资料已直接从 Goodnotes 送达。在下方提问，或先打开 AI 设置。")
                } else {
                    Spacer()
                    Text("在 Goodnotes 中选择笔记或文件夹，导出为 PDF 后选择“问 AI”。")
                        .foregroundStyle(.secondary).padding()
                    Button("AI 设置") { showSettings = true }.buttonStyle(.bordered)
                    Spacer()
                }
            }
            .disabled(model.isFinishing)
            .navigationTitle("问 AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("AI 设置", systemImage: "slider.horizontal.3") { showSettings = true }
                        .disabled(controller.isSending || model.isFinishing)
                        .accessibilityIdentifier("directShareSettings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("聊天记录", systemImage: "clock") { showHistory = true }
                        Button("另存资料副本", systemImage: "folder") { model.beginFileExport() }
                            .disabled(model.isReceiving || model.exportURLs.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("moreDirectShareActions")
                    .disabled(model.isFinishing || model.isReceiving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: finish).disabled(model.isExporting || model.isFinishing)
                        .accessibilityIdentifier("closeDirectShareWindow")
                }
            }
            .onChange(of: model.selection) { _, _ in resetChangedContext() }
            .onChange(of: includeContext) { _, _ in resetChangedContext() }
            .sheet(isPresented: $showSettings) { SettingsView(settings: settings) }
            .sheet(item: $preview) { DocumentPreview(request: $0) }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List(library.sessions.reversed()) { session in
                        Button(session.title) {
                            controller.cancel()
                            model.selection = session.context
                            includeContext = session.context.kind != .none
                            sessionID = session.id
                            showHistory = false
                        }
                    }
                    .navigationTitle("问 AI 聊天记录")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showHistory = false } } }
                }
            }
            .sheet(isPresented: $model.showFileExporter, onDismiss: model.fileExporterDismissed) {
                if let attemptID = model.fileExportAttemptID {
                    AttachmentFileExporter(urls: model.exportURLs) { model.fileExportCompleted($0, attemptID: attemptID) }
                        .interactiveDismissDisabled()
                }
            }
        }
    }

    private func resetChangedContext() {
        controller.cancel()
        let effective = includeContext ? model.selection : .none
        if library.sessions.first(where: { $0.id == sessionID })?.context != effective { sessionID = nil }
    }

    private func showCitation(_ citation: PageCitation) {
        guard let url = library.fileURL(for: citation) else {
            model.errorMessage = "此来源已不可用，请从 Goodnotes 重新分享资料。"
            return
        }
        preview = DocumentPreviewRequest(url: url, title: citation.documentTitle,
                                         pageNumber: citation.pageNumber, version: citation.version)
    }
}
