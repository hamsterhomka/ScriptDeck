import AppKit
import Observation

@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var workspaces: [Workspace] = []
    private(set) var sessions: [ScriptKey: RunSession] = [:]
    private(set) var runCounts: [String: Int] = [:]
    private var projectByWorkspace: [String: String] = [:]
    /// Явно закреплённые скрипты проекта; если ключа нет — работают умолчания (dev, start).
    private var pinnedScripts: [String: [String]] = [:]
    /// Пользовательский порядок проектов внутри мастер-папки.
    private var projectOrder: [String: [String]] = [:]
    /// Выбранный скрипт запоминается для каждой вкладки отдельно.
    private var selectionByProject: [String: ScriptKey] = [:]

    var currentWorkspaceID: String? {
        didSet { UserDefaults.standard.set(currentWorkspaceID, forKey: Self.currentWorkspaceKey) }
    }

    /// Домашняя вкладка: всё запущенное в системе. Не закрывается.
    static let homeID = "__home__"

    var isHomeSelected: Bool { currentWorkspaceID == Self.homeID }

    func selectHome() {
        currentWorkspaceID = Self.homeID
    }

    var currentWorkspace: Workspace? {
        workspaces.first { $0.id == currentWorkspaceID }
    }

    var selection: ScriptKey? {
        get {
            guard let selectedProjectPath else { return nil }
            return selectionByProject[selectedProjectPath]
        }
        set {
            if let newValue {
                selectionByProject[newValue.projectPath] = newValue
                sessions[newValue]?.markSeen()
                if newValue.projectPath != selectedProjectPath { selectedProjectPath = newValue.projectPath }
            } else if let selectedProjectPath {
                selectionByProject.removeValue(forKey: selectedProjectPath)
            }
            persistSelection()
        }
    }

    private static let workspacesKey = "workspaces"
    private static let legacyProjectsKey = "projects"
    private static let currentWorkspaceKey = "currentWorkspace"
    private static let selectionKey = "selectionByProject"
    private static let projectByWorkspaceKey = "projectByWorkspace"
    private static let runCountsKey = "runCounts"
    private static let projectOrderKey = "projectOrder"
    private static let pinnedScriptsKey = "pinnedScripts"

    private init() {
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: Self.workspacesKey)
            ?? defaults.stringArray(forKey: Self.legacyProjectsKey)
            ?? []
        pinnedScripts = (defaults.dictionary(forKey: Self.pinnedScriptsKey) as? [String: [String]]) ?? [:]
        projectOrder = (defaults.dictionary(forKey: Self.projectOrderKey) as? [String: [String]]) ?? [:]
        workspaces = paths.map { load($0) }
        runCounts = (defaults.dictionary(forKey: Self.runCountsKey) as? [String: Int]) ?? [:]
        projectByWorkspace = (defaults.dictionary(forKey: Self.projectByWorkspaceKey) as? [String: String]) ?? [:]
        if let data = defaults.data(forKey: Self.selectionKey),
           let saved = try? JSONDecoder().decode([String: ScriptKey].self, from: data) {
            selectionByProject = saved
        }
        let savedCurrent = defaults.string(forKey: Self.currentWorkspaceKey)
        let isSavedValid = savedCurrent == Self.homeID || workspaces.contains { $0.id == savedCurrent }
        currentWorkspaceID = isSavedValid ? savedCurrent : Self.homeID
        persistWorkspaces()

        // Окружение shell снимаем заранее, чтобы первый запуск был мгновенным.
        DispatchQueue.global(qos: .userInitiated).async { _ = ShellEnvironment.resolved() }
    }

    // MARK: - Вкладки

    func addWorkspace(at url: URL) {
        var directory = url
        if directory.lastPathComponent == "package.json" { directory.deleteLastPathComponent() }
        let path = directory.standardizedFileURL.path
        if workspaces.contains(where: { $0.path == path }) {
            currentWorkspaceID = path
            return
        }
        let workspace = load(path)
        workspaces.append(workspace)
        currentWorkspaceID = path
        persistWorkspaces()
        if selection == nil, !workspace.isGroup, let project = workspace.projects.first, let script = project.scripts.first {
            selection = ScriptKey(projectPath: project.path, scriptName: script.name)
        }
    }

    func closeWorkspace(_ workspace: Workspace) {
        let paths = Set(workspace.projects.map(\.path))
        // Скрипт может жить и в другой вкладке (тот же проект открыт дважды) — его не трогаем.
        let pathsElsewhere = Set(workspaces.filter { $0.id != workspace.id }.flatMap { $0.projects.map(\.path) })
        for (key, session) in sessions where paths.contains(key.projectPath) && !pathsElsewhere.contains(key.projectPath) {
            session.stop()
        }
        let index = workspaces.firstIndex { $0.id == workspace.id }
        workspaces.removeAll { $0.id == workspace.id }
        if currentWorkspaceID == workspace.id {
            let nextIndex = min(index ?? 0, workspaces.count - 1)
            currentWorkspaceID = nextIndex >= 0 ? workspaces[nextIndex].id : Self.homeID
        }
        persistWorkspaces()
        persistSelection()
    }

    func moveWorkspace(_ id: String, before targetID: String) {
        guard id != targetID, let from = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let item = workspaces.remove(at: from)
        let to = workspaces.firstIndex { $0.id == targetID } ?? workspaces.count
        workspaces.insert(item, at: to)
        persistWorkspaces()
    }

    func moveProjects(in workspace: Workspace, from source: IndexSet, to destination: Int) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].projects.move(fromOffsets: source, toOffset: destination)
        projectOrder[workspace.id] = workspaces[index].projects.map(\.path)
        UserDefaults.standard.set(projectOrder, forKey: Self.projectOrderKey)
    }

    /// Загружает вкладку и раскладывает проекты в сохранённом порядке; новые — в конец.
    private func load(_ path: String) -> Workspace {
        var workspace = Workspace.load(path: path)
        guard let order = projectOrder[path], !order.isEmpty else { return workspace }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        workspace.projects = workspace.projects.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.path] ?? (order.count + lhs.offset)
            let right = rank[rhs.element.path] ?? (order.count + rhs.offset)
            return left < right
        }.map(\.element)
        return workspace
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        currentWorkspaceID = workspaces[index].id
    }

    func selectAdjacentWorkspace(offset: Int) {
        let ids = [Self.homeID] + workspaces.map(\.id)
        let current = ids.firstIndex { $0 == currentWorkspaceID } ?? 0
        currentWorkspaceID = ids[(current + offset + ids.count) % ids.count]
    }

    func rescan(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index] = load(workspace.path)
    }

    func reloadAll() {
        workspaces = workspaces.map { load($0.path) }
    }

    /// Открывает вкладку, в которой лежит скрипт, и выбирает его.
    func reveal(_ key: ScriptKey) {
        if currentWorkspace?.projects.contains(where: { $0.path == key.projectPath }) != true,
           let workspace = workspaces.first(where: { $0.projects.contains { $0.path == key.projectPath } }) {
            currentWorkspaceID = workspace.id
        }
        selection = key
    }

    // MARK: - Выбор проекта (мастер-папка)

    var selectedProjectPath: String? {
        get {
            guard let workspace = currentWorkspace else { return nil }
            if let saved = projectByWorkspace[workspace.id], workspace.projects.contains(where: { $0.path == saved }) {
                return saved
            }
            return workspace.projects.first?.path
        }
        set {
            guard let currentWorkspaceID else { return }
            projectByWorkspace[currentWorkspaceID] = newValue
            UserDefaults.standard.set(projectByWorkspace, forKey: Self.projectByWorkspaceKey)
        }
    }

    // MARK: - Закреплённые скрипты

    private static func isPinnedByDefault(_ name: String) -> Bool {
        name == "dev" || name.hasPrefix("dev:") || name == "start"
    }

    private func pinnedNames(in project: Project) -> Set<String> {
        if let explicit = pinnedScripts[project.path] { return Set(explicit) }
        return Set(project.scripts.map(\.name).filter(Self.isPinnedByDefault))
    }

    func isPinned(_ script: Script, in project: Project) -> Bool {
        pinnedNames(in: project).contains(script.name)
    }

    func togglePin(_ script: Script, in project: Project) {
        var names = pinnedNames(in: project)
        if names.contains(script.name) { names.remove(script.name) } else { names.insert(script.name) }
        pinnedScripts[project.path] = project.scripts.map(\.name).filter(names.contains)
        UserDefaults.standard.set(pinnedScripts, forKey: Self.pinnedScriptsKey)
    }

    /// Делит скрипты на видимые (закреплённые и запущенные) и спрятанные под «Ещё».
    /// Если закреплять нечего и пользователь ничего не настраивал — показываем всё.
    func splitByPin(_ scripts: [Script], in project: Project) -> (visible: [Script], hidden: [Script]) {
        let pinned = pinnedNames(in: project)
        if pinned.isEmpty, pinnedScripts[project.path] == nil { return (scripts, []) }
        var visible: [Script] = []
        var hidden: [Script] = []
        for script in scripts {
            let key = ScriptKey(projectPath: project.path, scriptName: script.name)
            if pinned.contains(script.name) || state(for: key).isActive || selection == key {
                visible.append(script)
            } else {
                hidden.append(script)
            }
        }
        return (visible, hidden)
    }

    // MARK: - Частота запусков

    func runCount(_ key: ScriptKey) -> Int {
        runCounts[Self.usageID(key)] ?? 0
    }

    /// Самые запускаемые скрипты — сверху; при равенстве сохраняется порядок из package.json.
    func sortedByUsage(_ scripts: [Script], in project: Project) -> [Script] {
        scripts.enumerated().sorted { lhs, rhs in
            let left = runCount(ScriptKey(projectPath: project.path, scriptName: lhs.element.name))
            let right = runCount(ScriptKey(projectPath: project.path, scriptName: rhs.element.name))
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    private func recordRun(_ key: ScriptKey) {
        runCounts[Self.usageID(key), default: 0] += 1
        UserDefaults.standard.set(runCounts, forKey: Self.runCountsKey)
    }

    private static func usageID(_ key: ScriptKey) -> String {
        key.projectPath + "\u{0}" + key.scriptName
    }

    // MARK: - Поиск

    var allProjects: [Project] {
        workspaces.flatMap(\.projects)
    }

    func project(for key: ScriptKey) -> Project? {
        if let project = currentWorkspace?.projects.first(where: { $0.path == key.projectPath }) { return project }
        return allProjects.first { $0.path == key.projectPath }
    }

    func script(for key: ScriptKey) -> Script? {
        project(for: key)?.scripts.first { $0.name == key.scriptName }
    }

    func activeSessions(in workspace: Workspace) -> [RunSession] {
        let paths = Set(workspace.projects.map(\.path))
        return activeSessions.filter { paths.contains($0.key.projectPath) }
    }

    func activeCount(in project: Project) -> Int {
        sessions.values.filter { $0.state.isActive && $0.key.projectPath == project.path }.count
    }

    func hasUnseenError(in project: Project) -> Bool {
        sessions.values.contains { $0.hasUnseenError && $0.key.projectPath == project.path }
    }

    func hasUnseenError(in workspace: Workspace) -> Bool {
        let paths = Set(workspace.projects.map(\.path))
        return sessions.values.contains { $0.hasUnseenError && paths.contains($0.key.projectPath) }
    }

    // MARK: - Запуск

    func session(for key: ScriptKey) -> RunSession? {
        sessions[key]
    }

    func state(for key: ScriptKey) -> RunState {
        sessions[key]?.state ?? .idle
    }

    var activeSessions: [RunSession] {
        sessions.values.filter { $0.state.isActive }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    func run(_ key: ScriptKey) {
        guard let project = project(for: key) else { return }
        let command = project.packageManager.runCommand(for: key.scriptName)
        recordRun(key)
        ensureSession(for: key, command: command).start(command: command, directory: project.url)
    }

    func restart(_ key: ScriptKey) {
        guard let project = project(for: key) else { return }
        let command = project.packageManager.runCommand(for: key.scriptName)
        recordRun(key)
        ensureSession(for: key, command: command).restart(command: command, directory: project.url)
    }

    func stop(_ key: ScriptKey) {
        sessions[key]?.stop()
    }

    func toggle(_ key: ScriptKey) {
        if state(for: key).isActive { stop(key) } else { run(key) }
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
    }

    func killAllSynchronously() {
        for session in sessions.values { session.killSynchronously() }
    }

    private func ensureSession(for key: ScriptKey, command: String) -> RunSession {
        if let existing = sessions[key] { return existing }
        let session = RunSession(key: key, displayCommand: command)
        session.onStateChange = { [weak self] session in
            self?.notifyIfNeeded(session)
        }
        sessions[key] = session
        return session
    }

    private func notifyIfNeeded(_ session: RunSession) {
        // Бейдж в доке с количеством запущенных скриптов.
        let count = activeSessions.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        if case .exited(let code) = session.state, code != 0, selection != session.key {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - Сохранение

    private func persistWorkspaces() {
        UserDefaults.standard.set(workspaces.map(\.path), forKey: Self.workspacesKey)
    }

    private func persistSelection() {
        if let data = try? JSONEncoder().encode(selectionByProject) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }
}
