import SwiftUI
import UniformTypeIdentifiers

/// Левая колонка мастер-папки: список проектов.
struct ProjectsColumn: View {
    @Environment(ProjectStore.self) private var store
    let workspace: Workspace

    var body: some View {
        @Bindable var store = store
        let running = store.activeSessions(in: workspace)

        List(selection: $store.selectedProjectPath) {
            if !running.isEmpty {
                Section("Запущено") {
                    ForEach(running) { session in
                        RunningRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { store.reveal(session.key) }
                    }
                }
            }
            Section("Проекты") {
                ForEach(workspace.projects) { project in
                    ProjectRow(project: project, displayName: shortName(project.title))
                        .tag(project.path)
                }
                .onMove { source, destination in
                    store.moveProjects(in: workspace, from: source, to: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SubtleScrollers())
        .overlay {
            if workspace.projects.isEmpty {
                ContentUnavailableView("Проекты не найдены", systemImage: "questionmark.folder",
                                       description: Text("В папке нет package.json со скриптами"))
            }
        }
        .workspaceDropTarget()
    }

    /// «void-vpn-admin» во вкладке «void-vpn» → «admin».
    private func shortName(_ title: String) -> String {
        for separator in ["-", "_", "."] {
            let prefix = workspace.name + separator
            if title.hasPrefix(prefix), title.count > prefix.count { return String(title.dropFirst(prefix.count)) }
        }
        return title
    }
}

private struct ProjectRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let displayName: String

    var body: some View {
        let running = store.activeCount(in: project)
        let hasError = store.hasUnseenError(in: project)
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(running > 0 ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .fontWeight(running > 0 ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(project.scripts.count) скр. · \(project.packageManager.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hasError {
                Circle().fill(.red).frame(width: 7, height: 7)
            } else if running > 0 {
                Text("\(running)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.green, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .help(project.path)
        .contextMenu { ProjectMenuItems(project: project) }
    }
}

/// Колонка скриптов. В мастер-папке показывает выбранный проект, а при поиске — совпадения по всем проектам.
struct ScriptsColumn: View {
    @Environment(ProjectStore.self) private var store
    let workspace: Workspace?
    let onAddWorkspace: () -> Void
    @State private var query = ""
    @State private var expandedProjects: Set<String> = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var visibleProjects: [Project] {
        guard let workspace else { return [] }
        if workspace.isGroup, trimmedQuery.isEmpty {
            return workspace.projects.filter { $0.path == store.selectedProjectPath }
        }
        return workspace.projects
    }

    var body: some View {
        @Bindable var store = store
        let isGroup = workspace?.isGroup == true
        let running = (!isGroup && trimmedQuery.isEmpty) ? (workspace.map { store.activeSessions(in: $0) } ?? []) : []

        VStack(spacing: 0) {
            if workspace != nil {
                SearchField(text: $query, prompt: isGroup ? "Поиск по всем проектам" : "Поиск скрипта")
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            scriptList(running: running)
        }
        .overlay {
            if workspace == nil {
                ContentUnavailableView {
                    Label("Нет вкладок", systemImage: "shippingbox")
                } description: {
                    Text("Откройте папку проекта или мастер-папку\nс несколькими проектами внутри")
                } actions: {
                    Button("Открыть папку…", action: onAddWorkspace)
                        .buttonStyle(.borderedProminent)
                }
            } else if !trimmedQuery.isEmpty, visibleProjects.allSatisfy({ filtered($0).isEmpty }) {
                ContentUnavailableView.search(text: trimmedQuery)
            } else if isGroup, visibleProjects.isEmpty, workspace?.projects.isEmpty == false {
                ContentUnavailableView("Выберите проект", systemImage: "sidebar.left")
            }
        }
        .workspaceDropTarget()
    }

    private func scriptList(running: [RunSession]) -> some View {
        @Bindable var store = store
        return List(selection: $store.selection) {
            if !running.isEmpty {
                Section("Запущено") {
                    ForEach(running) { session in
                        RunningRow(session: session).tag(session.key)
                    }
                }
            }
            ForEach(visibleProjects) { project in
                let scripts = filtered(project)
                if !scripts.isEmpty || trimmedQuery.isEmpty {
                    Section {
                        if let error = project.loadError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        if trimmedQuery.isEmpty {
                            let split = store.splitByPin(scripts, in: project)
                            rows(split.visible, in: project)
                            if !split.hidden.isEmpty {
                                MoreRow(count: split.hidden.count, isExpanded: expandedProjects.contains(project.path)) {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if expandedProjects.contains(project.path) {
                                            expandedProjects.remove(project.path)
                                        } else {
                                            expandedProjects.insert(project.path)
                                        }
                                    }
                                }
                                if expandedProjects.contains(project.path) {
                                    rows(split.hidden, in: project)
                                        .opacity(0.8)
                                }
                            }
                        } else {
                            rows(scripts, in: project)
                        }
                    } header: {
                        ProjectHeader(project: project)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SubtleScrollers())
    }

    private func rows(_ scripts: [Script], in project: Project) -> some View {
        ForEach(scripts) { script in
            ScriptRow(project: project, script: script)
                .tag(ScriptKey(projectPath: project.path, scriptName: script.name))
        }
    }

    private func filtered(_ project: Project) -> [Script] {
        let text = trimmedQuery
        let scripts = store.sortedByUsage(project.scripts, in: project)
        guard !text.isEmpty else { return scripts }
        if project.title.localizedCaseInsensitiveContains(text) { return scripts }
        return scripts.filter {
            $0.name.localizedCaseInsensitiveContains(text) || $0.command.localizedCaseInsensitiveContains(text)
        }
    }
}

/// Свёрнутые незакреплённые скрипты.
private struct MoreRow: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
                Text(isExpanded ? "Скрыть остальные" : "Ещё \(count) \(Self.scriptsWord(count))")
                    .font(.callout)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .padding(.vertical, 1)
    }

    private static func scriptsWord(_ count: Int) -> String {
        let lastTwo = count % 100
        let last = count % 10
        if (11...14).contains(lastTwo) { return "скриптов" }
        if last == 1 { return "скрипт" }
        if (2...4).contains(last) { return "скрипта" }
        return "скриптов"
    }
}

private struct WorkspaceDropTarget: ViewModifier {
    @Environment(ProjectStore.self) private var store
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls { store.addWorkspace(at: url) }
                return !urls.isEmpty
            } isTargeted: { isTargeted = $0 }
    }
}

extension View {
    /// Перетащенная папка открывается новой вкладкой.
    func workspaceDropTarget() -> some View {
        modifier(WorkspaceDropTarget())
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = ""; isFocused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onReceive(NotificationCenter.default.publisher(for: .focusScriptSearch)) { _ in isFocused = true }
    }
}

extension Notification.Name {
    static let focusScriptSearch = Notification.Name("ScriptDeck.focusScriptSearch")
}

private struct ProjectHeader: View {
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            Text(project.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(project.packageManager.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            Menu {
                ProjectMenuItems(project: project)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(project.path)
    }
}

private struct ProjectMenuItems: View {
    let project: Project

    var body: some View {
        Button("Показать в Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Button("Открыть в Терминале", systemImage: "terminal") {
            NSWorkspace.shared.open([project.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        Button("Копировать путь", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
    }
}

private struct ScriptRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let script: Script
    @State private var isHovered = false

    private var key: ScriptKey { ScriptKey(projectPath: project.path, scriptName: script.name) }

    var body: some View {
        let state = store.state(for: key)
        HStack(spacing: 8) {
            StatusDot(state: state, hasUnseenError: store.session(for: key)?.hasUnseenError ?? false)
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name)
                    .fontWeight(state.isActive ? .semibold : .regular)
                Text(script.command)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if isHovered {
                PinButton(isPinned: store.isPinned(script, in: project)) {
                    withAnimation(.snappy(duration: 0.2)) { store.togglePin(script, in: project) }
                }
            }
            if isHovered || state.isActive {
                RunToggleButton(key: key, state: state)
            } else if store.runCount(key) > 0 {
                Text("\(store.runCount(key))×")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Запусков: \(store.runCount(key))")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(script.command)
        .contextMenu {
            Button(state.isActive ? "Остановить" : "Запустить") { store.toggle(key) }
            Button("Перезапустить") { store.restart(key) }
            Divider()
            Button(store.isPinned(script, in: project) ? "Открепить" : "Закрепить") {
                withAnimation(.snappy(duration: 0.2)) { store.togglePin(script, in: project) }
            }
            Divider()
            Button("Копировать команду") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.packageManager.runCommand(for: script.name), forType: .string)
            }
        }
    }
}

private struct RunningRow: View {
    @Environment(ProjectStore.self) private var store
    let session: RunSession

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: session.state, hasUnseenError: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.key.scriptName).fontWeight(.semibold)
                Text(store.project(for: session.key)?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let url = session.detectedURL, session.state.isActive {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help(url.absoluteString)
            }
            RunToggleButton(key: session.key, state: session.state)
        }
        .padding(.vertical, 2)
    }
}

private struct PinButton: View {
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isPinned ? Theme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Открепить — спрятать в «Ещё»" : "Закрепить — всегда показывать")
    }
}

struct RunToggleButton: View {
    @Environment(ProjectStore.self) private var store
    let key: ScriptKey
    let state: RunState

    var body: some View {
        Button {
            store.toggle(key)
        } label: {
            Image(systemName: state.isActive ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(state.isActive ? Color.red : Color.green)
                .frame(width: 22, height: 22)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .stopping)
        .help(state.isActive ? "Остановить" : "Запустить")
    }
}

struct StatusDot: View {
    let state: RunState
    let hasUnseenError: Bool

    var body: some View {
        ZStack {
            if state == .running {
                Circle()
                    .fill(Color.green.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .phaseAnimator([false, true]) { view, phase in
                        view.scaleEffect(phase ? 1.0 : 0.5).opacity(phase ? 0 : 1)
                    } animation: { _ in .easeOut(duration: 1.4) }
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .stopping: .orange
        case .exited(let code) where code != 0: hasUnseenError ? .red : .red.opacity(0.6)
        case .failed: .red
        case .exited: .green.opacity(0.5)
        case .idle, .stopped: .secondary.opacity(0.4)
        }
    }
}
