import SwiftUI

@main
@MainActor
struct NoteAssistantApp: App {
    @StateObject private var runtime = NoteAssistantRuntime()
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains(LibraryManagementUITestHost.launchArgument) {
                LibraryManagementUITestHost()
            } else if ProcessInfo.processInfo.arguments.contains(DirectShareUITestHost.launchArgument) {
                DirectShareUITestHost()
            } else if ProcessInfo.processInfo.arguments.contains("--ui-chat-scroll-regression") {
                ChatPanelUITestHost()
            } else {
                NoteAssistantRoot(library: runtime.library, settings: runtime.settings)
            }
            #else
            NoteAssistantRoot(library: runtime.library, settings: runtime.settings)
            #endif
        }
    }
}

@MainActor
private final class NoteAssistantRuntime: ObservableObject {
    // Preserve shared stores across windows; test hosts never access them.
    lazy var library = LibraryStore()
    lazy var settings = SettingsStore()
}

@MainActor
private struct NoteAssistantRoot: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ContentView(library: library, settings: settings)
            .task {
                await library.consumeSharedImports()
                if ProcessInfo.processInfo.arguments.contains("--export-signing-diagnostics") {
                    _ = try? await SigningDiagnostics.export(destination: SharedContainer.localRoot().appendingPathComponent("diagnostics"))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    settings.reload()
                    Task { await library.consumeSharedImports() }
                } else {
                    library.save()
                }
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                Task { await library.importFiles([url]) }
            }
    }
}
