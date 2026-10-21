import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // При запуске из `swift run` без .app-бандла иначе не будет иконки в доке и фокуса.
        NSApp.setActivationPolicy(.regular)
        installTerminationSignalHandlers()
        MainActor.assumeIsolated { SystemMonitor.shared.start() }
        AppAppearance.current.apply()
        NSApp.activate()
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// `kill`/`pkill` не проходят через applicationWillTerminate — без этого dev-серверы остаются сиротами.
    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { ProjectStore.shared.killAllSynchronously() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { ProjectStore.shared.activeSessions.count }
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Остановить запущенные скрипты?"
        alert.informativeText = "Сейчас работает: \(running). Они будут остановлены при выходе."
        alert.addButton(withTitle: "Остановить и выйти")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ProjectStore.shared.killAllSynchronously() }
    }
}

@main
struct ScriptDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ProjectStore.shared
    @AppStorage(DarkPalette.storageKey) private var palette: DarkPalette = .webstorm

    init() {
        // Отладка сканера: `ScriptDeck --scan` печатает найденные в системе скрипты.
        if CommandLine.arguments.contains("--scan") {
            for script in SystemProcesses.scan() {
                print(script.pid, script.user, script.name, "|", script.command, "|", script.directory ?? "-",
                      "| ports:", script.ports, "| source:", script.source ?? "-", script.isOrphan ? "(orphan)" : "")
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("ScriptDeck", id: "main") {
            ContentView()
                .environment(store)
                .tint(Theme.accent)
                // Палитра читается при отрисовке — пересобираем окно, чтобы всё перекрасилось.
                .id(palette)
                .frame(minWidth: 820, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            ScriptCommands(store: store)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            let count = store.activeSessions.count
            Image(systemName: count > 0 ? "terminal.fill" : "terminal")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var isImporterPresented = false

    var body: some View {
        Group {
            if store.isHomeSelected {
                HomeView()
            } else {
                ColumnsLayout(onAddWorkspace: { isImporterPresented = true })
            }
        }
        .id(store.currentWorkspaceID)
        .toolbar(.hidden, for: .windowToolbar)
        .background(Theme.detailBackground)
        .safeAreaInset(edge: .top, spacing: 0) {
            TabBarView(isImporterPresented: $isImporterPresented)
        }
        .ignoresSafeArea(.container, edges: .top)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { store.addWorkspace(at: url) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkspacePanel)) { _ in
            isImporterPresented = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reloadAll() }
        }
    }
}

extension Notification.Name {
    static let openWorkspacePanel = Notification.Name("ScriptDeck.openWorkspacePanel")
}

struct ScriptCommands: Commands {
    let store: ProjectStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть папку…") {
                NotificationCenter.default.post(name: .openWorkspacePanel, object: nil)
            }
            .keyboardShortcut("t")
        }

        CommandGroup(before: .sidebar) {
            AppearancePicker()
            PalettePicker()
            Divider()
        }

        CommandGroup(after: .textEditing) {
            Button("Найти скрипт") {
                NotificationCenter.default.post(name: .focusScriptSearch, object: nil)
            }
            .keyboardShortcut("p")
        }

        CommandMenu("Вкладки") {
            Button("Следующая вкладка") { store.selectAdjacentWorkspace(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Предыдущая вкладка") { store.selectAdjacentWorkspace(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Главная") { store.selectHome() }
                .keyboardShortcut("0")
            ForEach(Array(store.workspaces.prefix(9).enumerated()), id: \.element.id) { index, workspace in
                Button(workspace.name) { store.selectWorkspace(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Закрыть вкладку") {
                if let workspace = store.currentWorkspace { store.closeWorkspace(workspace) }
            }
            .disabled(store.currentWorkspace == nil)
        }

        CommandMenu("Скрипт") {
            Button("Запустить / Остановить") {
                if let key = store.selection { store.toggle(key) }
            }
            .keyboardShortcut("r")

            Button("Перезапустить") {
                if let key = store.selection { store.restart(key) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Остановить") {
                if let key = store.selection { store.stop(key) }
            }
            .keyboardShortcut(".")

            Divider()

            Button("Очистить лог") {
                if let key = store.selection { store.session(for: key)?.clear() }
            }
            .keyboardShortcut("k")

            Button("Открыть в браузере") {
                if let key = store.selection, let url = store.session(for: key)?.detectedURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Divider()

            Button("Остановить все") { store.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}

struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Picker("Тема", selection: $appearance) {
            ForEach(AppAppearance.allCases) { option in
                Label(option.title, systemImage: option.icon).tag(option)
            }
        }
        .onChange(of: appearance) { _, value in value.apply() }
    }
}

struct PalettePicker: View {
    @AppStorage(DarkPalette.storageKey) private var palette: DarkPalette = .webstorm

    var body: some View {
        Picker("Палитра", selection: $palette) {
            ForEach(DarkPalette.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}
