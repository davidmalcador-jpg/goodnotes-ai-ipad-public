import SwiftUI
import UniformTypeIdentifiers

private enum SidebarSelection: Hashable {
    case newChat
    case document(UUID)
    case collection(UUID)
    case session(UUID)
}

private enum ImportPurpose {
    case documents
    case update(UUID)
    case backup
}

@MainActor
struct ContentView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var settings: SettingsStore
    @StateObject private var chat: ChatController
    @State private var selectedSidebar: SidebarSelection?
    @State private var activeSessionID: UUID?
    @State private var selectedContext = ContextSelection.none
    @State private var includeContext = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var importPurpose = ImportPurpose.documents
    @State private var importCollectionName: String?
    @State private var showCollectionPrompt = false
    @State private var collectionName = ""
    @State private var showBackupPrompt = false
    @State private var preview: DocumentPreviewRequest?
    @State private var shareableFile: ShareableFile?
    @State private var preparingBackup = false
    @State private var pendingDeleteDocument: NotebookDocument?
    @State private var pendingDeleteCollection: DocumentCollection?
    @State private var showCollectionEditor = false
    @State private var editingCollectionID: UUID?
    @State private var collectionEditorName = ""
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    init(library: LibraryStore, settings: SettingsStore) {
        self.library = library
        self.settings = settings
        _chat = StateObject(wrappedValue: ChatController(library: library, settings: settings))
    }

    private var importerTypes: [UTType] {
        switch importPurpose {
        case .backup: return [.zip]
        case .update: return [.pdf, .image]
        case .documents: return [.pdf, .image, .zip]
        }
    }

    private var allowsMultipleImports: Bool {
        if case .documents = importPurpose { return true }
        return false
    }

    private var detailTitle: String {
        if let session = library.sessions.first(where: { $0.id == activeSessionID }) { return session.title }
        return "笔记问答"
    }

    private var selectedDocument: NotebookDocument? {
        let ids = selectedContext.resolvedDocumentIDs(in: library.documents)
        guard ids.count == 1 else { return nil }
        return library.documents.first(where: { ids.contains($0.id) })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("笔记问答")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("新建集合…", systemImage: "folder.badge.plus") { editCollection(nil) }
                                .disabled(chat.isSending)
                            Button("导入 PDF / 图片 / ZIP", systemImage: "square.and.arrow.down") { beginImport() }
                            Button("导入为新集合…", systemImage: "folder.badge.plus") {
                                collectionName = ""
                                showCollectionPrompt = true
                            }
                        } label: { Image(systemName: "plus") }
                        .accessibilityLabel("导入资料")
                        .disabled(library.isImporting)
                    }
                }
        } detail: {
            ChatPanel(
                library: library,
                controller: chat,
                sessionID: $activeSessionID,
                selectedContext: $selectedContext,
                includeContext: $includeContext,
                showCitation: openCitation,
                showSettings: { showSettings = true }
            )
            .navigationTitle(detailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("导入资料", systemImage: "square.and.arrow.down") { beginImport() }
                        if let document = selectedDocument {
                            Divider()
                            Button("查看所选资料", systemImage: "doc.text.magnifyingglass") { openDocument(document) }
                            Button("更新已有资料…", systemImage: "arrow.triangle.2.circlepath") {
                                importPurpose = .update(document.id)
                                showImporter = true
                            }
                            .disabled(library.isImporting || chat.isSending)
                        }
                        Divider()
                        Button("导出资料与聊天备份", systemImage: "externaldrive") { exportBackup() }
                            .disabled(preparingBackup || library.isImporting || chat.isSending)
                        Button("从备份合并恢复…", systemImage: "arrow.counterclockwise") { showBackupPrompt = true }
                            .disabled(library.isImporting || chat.isSending)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("moreChatActions")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if library.isImporting || preparingBackup {
                    HStack {
                        ProgressView()
                        Text(preparingBackup ? "正在准备备份…" : (library.statusMessage ?? "正在处理资料…"))
                            .font(.caption).lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedSidebar) { _, value in
            if let value { activate(value) }
        }
        .onChange(of: selectedContext) { _, _ in detachChangedContext() }
        .onChange(of: includeContext) { _, _ in detachChangedContext() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { chat.cancel() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importerTypes, allowsMultipleSelection: allowsMultipleImports) {
            handleImport($0)
        }
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings) }
        .sheet(item: $preview) { DocumentPreview(request: $0) }
        .sheet(item: $shareableFile) { FileShareSheet(url: $0.url) }
        .alert("新集合", isPresented: $showCollectionPrompt) {
            TextField("集合名称", text: $collectionName)
            Button("取消", role: .cancel) {}
            Button("选择文件") {
                let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                importCollectionName = name
                importPurpose = .documents
                showImporter = true
            }
        } message: {
            Text("选择多个文件或 Goodnotes 文件夹导出的 ZIP, 会创建集合供统一提问.")
        }
        .alert(editingCollectionID == nil ? "新建集合" : "重命名集合", isPresented: $showCollectionEditor) {
            TextField("集合名称", text: $collectionEditorName)
            Button(editingCollectionID == nil ? "创建" : "保存名称") { saveCollectionEditor() }
                .disabled(library.isImporting || chat.isSending || collectionEditorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("合并恢复资料与聊天", isPresented: $showBackupPrompt, titleVisibility: .visible) {
            Button("选择备份 ZIP") { importPurpose = .backup; showImporter = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复会加入备份中当前没有的资料与聊天, 保留现有内容. API Key 不在备份里.")
        }
        .confirmationDialog("删除资料?", isPresented: Binding(
            get: { pendingDeleteDocument != nil },
            set: { if !$0 { pendingDeleteDocument = nil } }
        ), titleVisibility: .visible) {
            if let document = pendingDeleteDocument {
                Button("删除资料", role: .destructive) {
                    library.deleteDocument(document.id)
                    if selectedSidebar == .document(document.id) { selectedSidebar = .newChat }
                    pendingDeleteDocument = nil
                }
            }
            Button("取消", role: .cancel) { pendingDeleteDocument = nil }
        } message: {
            Text("删除本地资料条目. 聊天引用对应的历史版本会保留, Goodnotes 中的原文档不受影响.")
        }
        .confirmationDialog("删除资料集合?", isPresented: Binding(
            get: { pendingDeleteCollection != nil },
            set: { if !$0 { pendingDeleteCollection = nil } }
        ), titleVisibility: .visible) {
            if let collection = pendingDeleteCollection {
                Button("删除集合及资料", role: .destructive) { deleteCollection(collection, withDocuments: true) }
                Button("仅解散集合") { deleteCollection(collection, withDocuments: false) }
            }
            Button("取消", role: .cancel) { pendingDeleteCollection = nil }
        } message: {
            Text("解散后资料移到独立资料; 连同删除会移除集合内的资料条目. 历史引用来源和 Goodnotes 原文档保留.")
        }
        .alert("操作未完成", isPresented: Binding(
            get: { errorMessage != nil || library.errorMessage != nil },
            set: { if !$0 { errorMessage = nil; library.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil; library.errorMessage = nil }
        } message: {
            Text(errorMessage ?? library.errorMessage ?? "请重试.")
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSidebar) {
            Section {
                NavigationLink(value: SidebarSelection.newChat) {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("newChatNavigation")
                Button("AI 设置", systemImage: "slider.horizontal.3") { showSettings = true }
                    .accessibilityIdentifier("openAISettings")
            }
            if let warning = settings.storageWarning {
                Section {
                    Button { showSettings = true } label: {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if !library.collections.isEmpty {
                Section("资料集合") {
                    ForEach(library.collections) { collection in
                        DisclosureGroup {
                            ForEach(library.documents.filter { $0.collectionID == collection.id }
                                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })) { document in
                                libraryDocumentRow(document)
                            }
                        } label: {
                            HStack {
                                NavigationLink(value: SidebarSelection.collection(collection.id)) {
                                    Label {
                                        HStack {
                                            Text(collection.name)
                                            Spacer()
                                            Text("\(library.documents.filter { $0.collectionID == collection.id }.count)")
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: { Image(systemName: "folder") }
                                }
                                Menu {
                                    Button("重命名", systemImage: "pencil") { editCollection(collection) }
                                    Button("删除集合…", systemImage: "trash", role: .destructive) { pendingDeleteCollection = collection }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .accessibilityLabel("管理集合 \(collection.name)")
                                .disabled(library.isImporting || chat.isSending)
                            }
                        }
                    }
                }
            }
            Section("独立资料") {
                let knownCollections = Set(library.collections.map(\.id))
                let standalone = library.documents.filter { document in
                    document.collectionID.map { !knownCollections.contains($0) } ?? true
                }.sorted(by: { $0.importedAt > $1.importedAt })
                if library.documents.isEmpty {
                    Text("从 Goodnotes 分享 PDF, 或点击 + 导入文件.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if standalone.isEmpty {
                    Text("资料已归入上方集合, 展开集合查看.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(standalone) { document in libraryDocumentRow(document) }
            }
            Section("历史对话") {
                ForEach(library.sessions) { session in
                    NavigationLink(value: SidebarSelection.session(session.id)) {
                        Label(session.title, systemImage: "bubble.left.and.bubble.right")
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("删除对话", systemImage: "trash", role: .destructive) {
                            library.sessions.removeAll(where: { $0.id == session.id })
                            library.save()
                            if activeSessionID == session.id { activeSessionID = nil; selectedSidebar = nil }
                        }
                        .disabled(chat.sendingSessionID == session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func libraryDocumentRow(_ document: NotebookDocument) -> some View {
        NavigationLink(value: SidebarSelection.document(document.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Label(document.title, systemImage: "doc.text").lineLimit(2)
                Text("\(document.pages.count) 页 · v\(document.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("查看资料", systemImage: "doc.text.magnifyingglass") { openDocument(document) }
            Button("更新已有资料…", systemImage: "arrow.triangle.2.circlepath") {
                importPurpose = .update(document.id)
                showImporter = true
            }
            .disabled(library.isImporting || chat.isSending)
            Menu("移到集合", systemImage: "folder") {
                ForEach(library.collections) { collection in
                    Button(collection.name) { library.moveDocument(document.id, toCollection: collection.id) }
                        .disabled(document.collectionID == collection.id)
                }
                if library.collections.isEmpty { Text("请先新建集合") }
            }
            .disabled(library.isImporting || chat.isSending)
            if document.collectionID != nil {
                Button("移出集合", systemImage: "folder.badge.minus") { library.moveDocument(document.id, toCollection: nil) }
                    .disabled(library.isImporting || chat.isSending)
            }
            Button("删除资料", systemImage: "trash", role: .destructive) { pendingDeleteDocument = document }
                .disabled(library.isImporting || chat.isSending)
        }
        .swipeActions {
            Button("删除", role: .destructive) { pendingDeleteDocument = document }
                .disabled(library.isImporting || chat.isSending)
        }
    }

    private func editCollection(_ collection: DocumentCollection?) {
        editingCollectionID = collection?.id
        collectionEditorName = collection?.name ?? ""
        showCollectionEditor = true
    }

    private func saveCollectionEditor() {
        if let id = editingCollectionID { library.renameCollection(id, to: collectionEditorName) }
        else { library.createCollection(named: collectionEditorName) }
    }

    private func deleteCollection(_ collection: DocumentCollection, withDocuments: Bool) {
        let memberIDs = Set(library.documents.filter { $0.collectionID == collection.id }.map(\.id))
        library.deleteCollection(collection.id, deleteDocuments: withDocuments)
        if selectedSidebar == .collection(collection.id) { selectedSidebar = .newChat }
        if let sidebarSelection = selectedSidebar, case .document(let id) = sidebarSelection, withDocuments, memberIDs.contains(id) { selectedSidebar = .newChat }
        pendingDeleteCollection = nil
    }

    private func activate(_ selection: SidebarSelection) {
        switch selection {
        case .newChat:
            activeSessionID = nil
            chat.errorMessage = nil
        case .document(let id):
            selectedContext = ContextSelection(kind: .document, targetID: id)
            includeContext = true
            activeSessionID = library.sessions.first(where: { $0.context.kind == .document && $0.context.targetID == id })?.id
        case .collection(let id):
            selectedContext = ContextSelection(kind: .collection, targetID: id)
            includeContext = true
            activeSessionID = library.sessions.first(where: { $0.context.kind == .collection && $0.context.targetID == id })?.id
        case .session(let id):
            guard let session = library.sessions.first(where: { $0.id == id }) else { return }
            activeSessionID = id
            selectedContext = session.context
            includeContext = session.context.kind != .none
        }
    }

    private func newChat() {
        activeSessionID = nil
        selectedSidebar = .newChat
        chat.errorMessage = nil
    }

    private func detachChangedContext() {
        let effective = includeContext ? selectedContext : .none
        guard let session = library.sessions.first(where: { $0.id == activeSessionID }),
              session.context != effective else { return }
        activeSessionID = nil
        selectedSidebar = .newChat
        chat.errorMessage = nil
    }

    private func beginImport() {
        importPurpose = .documents
        importCollectionName = selectedContext.kind == .collection
            ? library.collections.first(where: { $0.id == selectedContext.targetID })?.name : nil
        showImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            let purpose = importPurpose
            let collection = importCollectionName
            Task {
                switch purpose {
                case .documents:
                    await library.importFiles(urls, collectionName: collection)
                case .update(let id):
                    if let url = urls.first { await library.updateDocument(id, from: url) }
                case .backup:
                    if let url = urls.first { await library.importBackup(url) }
                }
            }
        }
    }

    private func openCitation(_ citation: PageCitation) {
        guard let url = library.fileURL(for: citation) else {
            errorMessage = "这条回答引用的资料版本已不在本机. 请恢复包含该版本的备份."
            return
        }
        preview = DocumentPreviewRequest(url: url, title: citation.documentTitle, pageNumber: citation.pageNumber, version: citation.version)
    }

    private func openDocument(_ document: NotebookDocument) {
        preview = DocumentPreviewRequest(url: library.fileURL(for: document), title: document.title, pageNumber: 1, version: document.version)
    }

    private func exportBackup() {
        preparingBackup = true
        Task {
            defer { preparingBackup = false }
            do { shareableFile = ShareableFile(url: try await library.exportBackup()) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
