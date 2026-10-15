import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var model = ""
    @State private var supportsImages = true
    @State private var replacementKey = ""
    @State private var hasSavedKey = false
    @State private var isTesting = false
    @State private var feedback: String?
    @State private var feedbackIsError = false
    @State private var testTask: Task<Void, Never>?
    @FocusState private var focusedField: SettingsField?

    var body: some View {
        NavigationStack {
            Form {
                Section("模型服务") {
                    if let error = settings.configurationError {
                        Text(error).foregroundStyle(.red)
                    }
                    HStack {
                        Button("DeepSeek Flash") { selectPreset(.deepSeek) }
                            .accessibilityIdentifier("chooseDeepSeekFlash")
                        Button("DeepSeek Pro") { selectPreset(.deepSeekPro) }
                            .accessibilityIdentifier("chooseDeepSeekPro")
                    }
                    .buttonStyle(.bordered)
                    TextField("API 地址", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .baseURL)
                        .accessibilityIdentifier("providerBaseURL")
                    TextField("模型名称", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .model)
                        .accessibilityIdentifier("providerModel")
                    Toggle("模型支持读取图片", isOn: $supportsImages)
                    Text("可选择 Flash / Pro, 也可直接填写其他模型标识. Pro 预设使用 deepseek-v4-pro 和文字资料; 服务实际提供的模型以供应商当前开放情况为准. 切换后点“完成”或“保存设置”, 已保存的 Key 会保留.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("使用兼容 OpenAI Chat Completions 的服务. 地址填写服务根地址或 /v1 地址; 请求由 iPad 直接发出.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("API Key") {
                    SecureField(hasSavedKey ? "已保存, 留空保留原 Key" : "请输入 API Key", text: $replacementKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)
                        .accessibilityIdentifier("providerAPIKey")
                    Text(settings.credentialScope == .extensionPrivate
                         ? "首次在“问 AI”中保存 Key 后, 可直接在 Goodnotes 分享界面提问. 设置与主 App 分开保存在本机, 以后无需重复填写. Key 不包含在资料备份里."
                         : "Key 保存在设备 Keychain 中, 不包含在资料备份里.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if hasSavedKey {
                        Button("移除已保存的 Key", role: .destructive) {
                            do {
                                try settings.saveAPIKey("")
                                hasSavedKey = false
                                replacementKey = ""
                                showFeedback("已移除 API Key.", isError: false)
                            } catch {
                                showFeedback(error.localizedDescription, isError: true)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        save()
                    } label: {
                        Label("保存设置", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("saveAISettings")
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "network")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                    if isTesting {
                        Button("取消测试", role: .cancel) { testTask?.cancel() }
                    }
                } footer: {
                    Text("连接测试会向所选服务发送一条简短请求, 可能产生少量 API 费用.")
                }
                Section("安装状态") {
                    if settings.isShareExtension {
                        Text("可直接读取本次从 Goodnotes 分享的资料并提问. 资料和聊天保存在本机, 也可按需导出副本.")
                    } else {
                        if let warning = settings.storageWarning {
                            Text(warning).foregroundStyle(.secondary)
                        } else {
                            Text("主 App 的资料和设置保存在本机. 可从 Goodnotes 的“问 AI”直接提问, 或将副本导入主 App 后并排使用.")
                        }
                        if !settings.isSharedKeychainAvailable {
                            Text("“问 AI”可单独保存 API Key 并直接提问. 主 App 已保存的 Key 会保留.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Text("普通 Apple ID 安装需要在 7 天到期前用数据线连接电脑, 使用同一账号和 App 标识覆盖续签. 请保留资料备份, 避免卸载 App.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let feedback {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                        Text(feedback)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settingsFeedback")
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(feedbackIsError ? Color.red : Color.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if save() { dismiss() }
                    }
                        .accessibilityIdentifier("closeAISettings")
                }
            }
            .onAppear {
                baseURL = settings.configuration.baseURL
                model = settings.configuration.model
                supportsImages = settings.configuration.supportsImages
                hasSavedKey = !((try? settings.apiKey()) ?? "").isEmpty
            }
            .onDisappear { testTask?.cancel() }
        }
    }

    private func selectPreset(_ configuration: ProviderConfiguration) {
        focusedField = nil
        baseURL = configuration.baseURL
        model = configuration.model
        supportsImages = configuration.supportsImages
    }

    private func proposedConfiguration() throws -> ProviderConfiguration {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.host != nil,
              url.scheme?.lowercased() == "https" else {
            throw SettingsError.invalidAddress
        }
        guard !trimmedModel.isEmpty else { throw SettingsError.missingModel }
        let configuration = ProviderConfiguration(baseURL: trimmedURL, model: trimmedModel, supportsImages: supportsImages)
        _ = try ProviderClient.endpoint(for: configuration)
        return configuration
    }

    private func effectiveKey() throws -> String {
        let replacement = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = replacement.isEmpty ? try settings.apiKey() : replacement
        guard !key.isEmpty else { throw SettingsError.missingKey }
        return key
    }

    @discardableResult
    private func save() -> Bool {
        focusedField = nil
        do {
            let configuration = try proposedConfiguration()
            let replacement = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !replacement.isEmpty {
                try settings.saveAPIKey(replacement)
                replacementKey = ""
                hasSavedKey = true
            }
            try settings.save(configuration)
            showFeedback("设置已保存.", isError: false)
            return true
        } catch {
            showFeedback(error.localizedDescription, isError: true)
            return false
        }
    }

    private func testConnection() {
        focusedField = nil
        do {
            let configuration = try proposedConfiguration()
            let key = try effectiveKey()
            isTesting = true
            feedback = nil
            testTask = Task {
                defer { isTesting = false; testTask = nil }
                do {
                    try await ProviderClient.testConnection(configuration: configuration, apiKey: key)
                    showFeedback("连接成功. 当前编辑值尚未保存时, 请点击“完成”或“保存设置”.", isError: false)
                } catch is CancellationError {
                    showFeedback("连接测试已取消.", isError: false)
                } catch {
                    if Task.isCancelled {
                        showFeedback("连接测试已取消.", isError: false)
                    } else {
                        showFeedback(error.localizedDescription, isError: true)
                    }
                }
            }
        } catch {
            showFeedback(error.localizedDescription, isError: true)
        }
    }

    private func showFeedback(_ message: String, isError: Bool) {
        feedback = message
        feedbackIsError = isError
    }
}

private enum SettingsField: Hashable {
    case baseURL, model, apiKey
}

private enum SettingsError: LocalizedError {
    case invalidAddress, missingModel, missingKey
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入有效的 API 地址, 例如 https://api.deepseek.com."
        case .missingModel: return "请输入模型名称."
        case .missingKey: return "请先输入 API Key."
        }
    }
}
