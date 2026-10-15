import SwiftUI

@MainActor
struct ContextPicker: View {
    @ObservedObject var library: LibraryStore
    @Binding var selection: ContextSelection
    @Binding var includeContext: Bool
    var isSending = false
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "multiple"
    @State private var documentID: UUID?
    @State private var documentIDs = Set<UUID>()
    @State private var collectionIDs = Set<UUID>()
    @State private var expandedCollections = Set<UUID>()
    @State private var pageText = ""
    @State private var error: String?
    @State private var pendingDeleteDocument: NotebookDocument?
    @State private var pendingDeleteCollection: DocumentCollection?
    @State private var showCollectionEditor = false
    @State private var editingCollectionID: UUID?
    @State private var collectionName = ""

    private var busy: Bool { isSending || library.isImporting }
    private var chosenDocument: NotebookDocument? {
        library.documents.first(where: { $0.id == documentID })
    }
    private var standaloneDocuments: [NotebookDocument] {
        let knownCollections = Set(library.collections.map(\.id))
        return ordered(library.documents.filter { document in
            document.collectionID.map { !knownCollections.contains($0) } ?? true
        })
    }
    private var chosenIDs: Set<UUID> {
        if mode == "none" { return [] }
        if mode != "multiple" { return Set(documentID.map { [$0] } ?? []) }
        return Set(library.documents.filter { document in
            documentIDs.contains(document.id) || document.collectionID.map(collectionIDs.contains) == true
        }.map(\.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提问范围") {
                    Picker("范围", selection: $mode) {
                        Text("多选资料与集合").tag("multiple")
                        Text("一份资料").tag("document")
                        Text("指定页").tag("pages")
                        Text("不附带资料").tag("none")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("contextScope")
                    if mode != "none" {
                        Text(mode == "multiple"
                             ? "已选 \(collectionIDs.count) 个集合 · \(documentIDs.count) 份单独资料 · 共 \(chosenIDs.count) 份"
                             : "已选 \(chosenIDs.count) 份资料")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("contextSelectionSummary")
                    }
                    if mode == "pages" {
                        TextField("页码, 例如 1,3-5", text: $pageText)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("contextPageNumbers")
                        Text("按导出 PDF 的页面顺序填写, 从 1 开始. 它可能与笔记上印刷的页码不同.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if mode != "none" {
                    if !library.collections.isEmpty {
                        Section("资料集合") {
                            ForEach(library.collections) { collection in collectionRow(collection) }
                        }
                    }
                    Section("独立资料") {
                        if standaloneDocuments.isEmpty {
                            Text(library.documents.isEmpty ? "从 Goodnotes 分享资料后, 会显示在这里." : "集合中的资料请展开上方集合查看.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(standaloneDocuments) { document in documentRow(document) }
                    }
                }
                Section {
                    Text("可以同时勾选多个集合和单份资料. 展开集合可单选文件; 重叠资料只发送一次. 取消已选集合内的一份资料, 会改选该集合的其余文件.")
                    Text("按问题选取相关页面并控制发送量. Goodnotes 修改或切换笔记后, 请重新分享; 这里使用已导入的资料副本.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                if let message = error ?? library.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("选择资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("contextCancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editCollection(nil) } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("新建集合")
                        .accessibilityIdentifier("contextNewCollection")
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { apply() }
                        .disabled(busy)
                        .accessibilityIdentifier("contextApply")
                }
            }
            .alert(editingCollectionID == nil ? "新建集合" : "重命名集合", isPresented: $showCollectionEditor) {
                TextField("集合名称", text: $collectionName)
                    .accessibilityIdentifier("collectionNameInput")
                Button(editingCollectionID == nil ? "创建" : "保存名称") { saveCollectionEditor() }
                    .accessibilityIdentifier(editingCollectionID == nil ? "collectionCreate" : "collectionRenameSave")
                    .disabled(busy || collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(editingCollectionID == nil ? "取消创建" : "取消重命名", role: .cancel) {}
            } message: {
                Text("集合名称用于本机整理资料, 不会更改 Goodnotes 中的原文件夹.")
            }
            .confirmationDialog("删除资料?", isPresented: Binding(
                get: { pendingDeleteDocument != nil },
                set: { if !$0 { pendingDeleteDocument = nil } }
            ), titleVisibility: .visible) {
                if let document = pendingDeleteDocument {
                    Button("删除资料", role: .destructive) {
                        library.deleteDocument(document.id)
                        refreshAfterDeletion()
                        pendingDeleteDocument = nil
                    }
                }
                Button("取消删除", role: .cancel) { pendingDeleteDocument = nil }
            } message: {
                Text("删除“\(pendingDeleteDocument?.title ?? "")”的本地资料条目. 历史对话引用的来源会保留, Goodnotes 原文档不受影响.")
            }
            .confirmationDialog("删除资料集合?", isPresented: Binding(
                get: { pendingDeleteCollection != nil },
                set: { if !$0 { pendingDeleteCollection = nil } }
            ), titleVisibility: .visible) {
                if let collection = pendingDeleteCollection {
                    Button("删除集合及资料", role: .destructive) { deleteCollection(collection, withDocuments: true) }
                    Button("仅解散集合") { deleteCollection(collection, withDocuments: false) }
                }
                Button("取消删除", role: .cancel) { pendingDeleteCollection = nil }
            } message: {
                Text("“\(pendingDeleteCollection?.name ?? "")”: 解散后资料移到独立资料; 连同删除会移除集合内的资料条目. 历史引用来源与 Goodnotes 原文档保留.")
            }
            .onAppear(perform: loadSelection)
            .onChange(of: mode) { _, value in
                if value == "document" || value == "pages" {
                    if documentID == nil {
                        let selected = documentIDs.union(selection.resolvedDocumentIDs(in: library.documents))
                        documentID = ordered(library.documents.filter { selected.contains($0.id) }).first?.id
                            ?? ordered(library.documents).first?.id
                    }
                    if let id = chosenDocument?.collectionID { expandedCollections.insert(id) }
                }
            }
        }
    }

    private func ordered(_ documents: [NotebookDocument]) -> [NotebookDocument] {
        documents.sorted {
            $0.title == $1.title ? $0.id.uuidString < $1.id.uuidString
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func members(_ collection: DocumentCollection) -> [NotebookDocument] {
        ordered(library.documents.filter { $0.collectionID == collection.id })
    }

    private func collectionRow(_ collection: DocumentCollection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if mode == "multiple" {
                Button { toggleCollection(collection) } label: {
                    Image(systemName: collectionIDs.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3).frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(collection.name)
                .accessibilityValue(collectionIDs.contains(collection.id) ? "已选" : "未选")
                .accessibilityIdentifier("selectCollection-\(collection.id.uuidString)")
                .disabled(busy || (members(collection).isEmpty && !collectionIDs.contains(collection.id)))
            }
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if expandedCollections.contains(collection.id) { expandedCollections.remove(collection.id) }
                    else { expandedCollections.insert(collection.id) }
                } label: {
                    HStack {
                        Image(systemName: expandedCollections.contains(collection.id) ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Label(collection.name, systemImage: "folder")
                        Spacer()
                        Text("\(members(collection).count)").foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("展开或收起 \(collection.name)")
                .accessibilityValue(expandedCollections.contains(collection.id) ? "已展开" : "已收起")
                .accessibilityIdentifier("collectionDisclosure-\(collection.id.uuidString)")
                if expandedCollections.contains(collection.id) {
                    ForEach(members(collection)) { document in documentRow(document) }
                    if members(collection).isEmpty { Text("集合中没有资料").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Menu {
                Button("重命名", systemImage: "pencil") { editCollection(collection) }
                    .accessibilityIdentifier("renameCollection-\(collection.id.uuidString)")
                Button("删除集合…", systemImage: "trash", role: .destructive) { pendingDeleteCollection = collection }
                    .accessibilityIdentifier("deleteCollection-\(collection.id.uuidString)")
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 32, minHeight: 44) }
            .accessibilityLabel("管理集合 \(collection.name)")
            .accessibilityIdentifier("collectionActions-\(collection.id.uuidString)")
            .disabled(busy)
        }
    }

    private func documentRow(_ document: NotebookDocument) -> some View {
        HStack(spacing: 10) {
            Button { toggleDocument(document) } label: {
                HStack(spacing: 10) {
                    Image(systemName: chosenIDs.contains(document.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Text("\(document.pages.count) 页 · v\(document.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(document.title)
            .accessibilityValue(chosenIDs.contains(document.id) ? "已选" : "未选")
            .accessibilityIdentifier("selectDocument-\(document.id.uuidString)")
            .disabled(busy)
            Menu {
                Menu("移到集合", systemImage: "folder") {
                    ForEach(library.collections) { collection in
                        Button("移到 \(collection.name)") { move(document, to: collection.id) }
                            .accessibilityIdentifier("moveDocument-\(document.id.uuidString)-to-\(collection.id.uuidString)")
                            .disabled(document.collectionID == collection.id)
                    }
                    if library.collections.isEmpty { Text("请先新建集合") }
                }
                .accessibilityIdentifier("moveDocumentMenu-\(document.id.uuidString)")
                if document.collectionID != nil {
                    Button("移出集合", systemImage: "folder.badge.minus") { move(document, to: nil) }
                        .accessibilityIdentifier("removeDocumentFromCollection-\(document.id.uuidString)")
                }
                Button("删除资料…", systemImage: "trash", role: .destructive) { pendingDeleteDocument = document }
                    .accessibilityIdentifier("deleteDocument-\(document.id.uuidString)")
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 32, minHeight: 44) }
            .accessibilityLabel("管理资料 \(document.title)")
            .accessibilityIdentifier("documentActions-\(document.id.uuidString)")
            .disabled(busy)
        }
    }

    private func editCollection(_ collection: DocumentCollection?) {
        editingCollectionID = collection?.id
        collectionName = collection?.name ?? ""
        showCollectionEditor = true
    }

    private func saveCollectionEditor() {
        if let id = editingCollectionID { library.renameCollection(id, to: collectionName) }
        else if let id = library.createCollection(named: collectionName) { expandedCollections.insert(id) }
    }

    private func move(_ document: NotebookDocument, to collectionID: UUID?) {
        guard library.moveDocument(document.id, toCollection: collectionID) else { return }
        if let collectionID { expandedCollections.insert(collectionID) }
        // Collection selection follows membership; explicit file selection follows its stable ID.
        selection = selection.normalized(documents: library.documents, collections: library.collections)
        if selection.kind == .none { includeContext = false }
    }

    private func toggleCollection(_ collection: DocumentCollection) {
        let ids = Set(members(collection).map(\.id))
        if collectionIDs.contains(collection.id) { collectionIDs.remove(collection.id) }
        else { collectionIDs.insert(collection.id) }
        documentIDs.subtract(ids)
        error = nil
    }

    private func toggleDocument(_ document: NotebookDocument) {
        if mode != "multiple" { documentID = document.id; error = nil; return }
        if let collectionID = document.collectionID, collectionIDs.contains(collectionID) {
            collectionIDs.remove(collectionID)
            documentIDs.formUnion(library.documents.filter { $0.collectionID == collectionID && $0.id != document.id }.map(\.id))
            documentIDs.remove(document.id)
        } else if !documentIDs.insert(document.id).inserted { documentIDs.remove(document.id) }
        error = nil
    }

    private func loadSelection() {
        let current = selection.normalized(documents: library.documents, collections: library.collections)
        mode = current.kind == .pages ? "pages" : "multiple"
        documentID = current.kind == .document || current.kind == .pages ? current.targetID : nil
        documentIDs = Set(current.documentIDs)
        collectionIDs = Set(current.collectionIDs)
        if let id = current.targetID {
            if current.kind == .collection { collectionIDs.insert(id) }
            else if current.kind == .document || current.kind == .pages { documentIDs.insert(id) }
        }
        expandedCollections = []
        for document in library.documents where documentIDs.contains(document.id) {
            if let id = document.collectionID { expandedCollections.insert(id) }
        }
        pageText = current.pageNumbers.map(String.init).joined(separator: ",")
    }

    private func refreshAfterDeletion() {
        documentIDs.formIntersection(library.documents.map(\.id))
        collectionIDs.formIntersection(library.collections.map(\.id))
        if !library.documents.contains(where: { $0.id == documentID }) { documentID = nil }
        selection = selection.normalized(documents: library.documents, collections: library.collections)
        if selection.kind == .none { includeContext = false }
    }

    private func deleteCollection(_ collection: DocumentCollection, withDocuments: Bool) {
        library.deleteCollection(collection.id, deleteDocuments: withDocuments)
        refreshAfterDeletion()
        pendingDeleteCollection = nil
    }

    private func apply() {
        error = nil
        switch mode {
        case "none": selection = .none; includeContext = false
        case "pages":
            guard let document = chosenDocument else { error = "请选择一份资料."; return }
            guard let numbers = parsePages(pageText, maximum: document.pages.count), !numbers.isEmpty else {
                error = "页码无效. 请填写 1 到 \(document.pages.count) 之间的页码, 例如 1,3-5."; return
            }
            selection = ContextSelection(kind: .pages, targetID: document.id, pageNumbers: numbers)
            includeContext = true
        case "document":
            guard let document = chosenDocument else { error = "请选择一份资料."; return }
            selection = ContextSelection(kind: .document, targetID: document.id)
            includeContext = true
        default:
            let value = ContextSelection(kind: .multiple, targetID: nil,
                                         documentIDs: Array(documentIDs), collectionIDs: Array(collectionIDs))
                .normalized(documents: library.documents, collections: library.collections)
            guard value.kind != .none, !chosenIDs.isEmpty else { error = "请至少选择一份资料或一个非空集合."; return }
            selection = value
            includeContext = true
        }
        dismiss()
    }

    private func parsePages(_ input: String, maximum: Int) -> [Int]? {
        var result = Set<Int>()
        let normalized = input.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",").replacingOccurrences(of: "–", with: "-")
        for part in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 1, let page = Int(bounds[0]), page >= 1, page <= maximum { result.insert(page) }
            else if bounds.count == 2,
                    let first = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                    let last = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                    first >= 1, last >= first, last <= maximum { result.formUnion(first...last) }
            else { return nil }
        }
        return result.sorted()
    }
}
