import SwiftUI

struct MenuBarContent: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ScriptDeck").font(.headline)
                Spacer()
                ThemeToggle()
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Открыть окно")
            }

            let active = store.activeSessions
            if active.isEmpty {
                Text("Ничего не запущено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(active) { session in
                        HStack(spacing: 8) {
                            StatusDot(state: session.state, hasUnseenError: false)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(session.key.scriptName).fontWeight(.medium)
                                Text(store.project(for: session.key)?.title ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = session.detectedURL {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                                    .buttonStyle(.borderless)
                            }
                            Button { store.restart(session.key) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                            RunToggleButton(key: session.key, state: session.state)
                        }
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.reveal(session.key)
                            openWindow(id: "main")
                            NSApp.activate()
                        }
                    }
                }
            }

            if !store.workspaces.isEmpty {
                Divider()
                Text("Быстрый запуск").font(.caption).foregroundStyle(.secondary)
                ForEach(store.workspaces) { workspace in
                    Menu(workspace.name) {
                        if workspace.isGroup {
                            ForEach(workspace.projects) { project in
                                Menu(project.title) { scriptButtons(project) }
                            }
                        } else if let project = workspace.projects.first {
                            scriptButtons(project)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Остановить все") { store.stopAll() }
                    .disabled(active.isEmpty)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func scriptButtons(_ project: Project) -> some View {
        ForEach(project.scripts) { script in
            let key = ScriptKey(projectPath: project.path, scriptName: script.name)
            Button {
                store.toggle(key)
            } label: {
                Label(script.name, systemImage: store.state(for: key).isActive ? "stop.fill" : "play.fill")
            }
        }
    }
}

/// Быстрое переключение темы по кругу: системная → светлая → тёмная.
private struct ThemeToggle: View {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Button {
            let all = AppAppearance.allCases
            let next = all[(all.firstIndex(of: appearance)! + 1) % all.count]
            appearance = next
            next.apply()
        } label: {
            Image(systemName: appearance.icon)
        }
        .buttonStyle(.borderless)
        .help("Тема: \(appearance.title)")
    }
}
