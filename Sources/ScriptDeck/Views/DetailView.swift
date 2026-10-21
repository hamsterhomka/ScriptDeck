import SwiftUI

struct DetailView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        if let key = store.selection, let project = store.project(for: key), let script = store.script(for: key) {
            ScriptDetail(key: key, project: project, script: script)
                .id(key)
        } else {
            ContentUnavailableView("Выберите скрипт", systemImage: "terminal",
                                   description: Text("Слева — скрипты из package.json ваших проектов"))
        }
    }
}

private struct ScriptDetail: View {
    @Environment(ProjectStore.self) private var store
    let key: ScriptKey
    let project: Project
    let script: Script

    var body: some View {
        let session = store.session(for: key)
        VStack(spacing: 0) {
            header(session: session)
            Rectangle().fill(Theme.separator).frame(height: 1)
            ZStack {
                LogTextView(session: session, lineCount: session?.lines.count ?? 0, rebuildToken: session?.rebuildToken ?? 0)
                if session == nil {
                    VStack(spacing: 14) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Ещё не запускался")
                            .foregroundStyle(.white.opacity(0.6))
                        Button("Запустить  ⌘R") { store.run(key) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
        }
        .navigationTitle(project.title)
        .onAppear { session?.markSeen() }
    }

    private func header(session: RunSession?) -> some View {
        let state = session?.state ?? .idle
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(script.name)
                        .font(.title2.weight(.semibold))
                    StateBadge(session: session)
                }
                Text(script.command)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()

            if let url = session?.detectedURL, state.isActive {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(url.host(percentEncoded: false).map { "\($0)\(url.port.map { ":\($0)" } ?? "")" } ?? "Открыть",
                          systemImage: "safari")
                }
                .help("Открыть \(url.absoluteString)")
            }

            ControlGroup {
                Button {
                    session?.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Очистить лог  ⌘K")
                .disabled(session == nil)

                Button {
                    if let text = session?.plainText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Скопировать весь лог")
                .disabled(session == nil)
            }
            .fixedSize()

            if state.isActive {
                Button {
                    store.restart(key)
                } label: {
                    Label("Рестарт", systemImage: "arrow.clockwise")
                }
                .help("Перезапустить  ⇧⌘R")
                Button(role: .destructive) {
                    store.stop(key)
                } label: {
                    Label("Стоп", systemImage: "stop.fill")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(state == .stopping)
                .help("Остановить  ⌘.")
            } else {
                Button {
                    store.run(key)
                } label: {
                    Label("Запустить", systemImage: "play.fill")
                }
                .tint(Theme.accent)
                .buttonStyle(.borderedProminent)
                .help("Запустить  ⌘R")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.header)
    }
}

private struct StateBadge: View {
    let session: RunSession?

    var body: some View {
        if let session {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(text(now: context.date, session: session))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(color(session.state))
                    .background(color(session.state).opacity(0.15), in: Capsule())
            }
        }
    }

    private func text(now: Date, session: RunSession) -> String {
        switch session.state {
        case .idle: return "не запущен"
        case .running: return "работает · \(duration(from: session.startedAt, to: now))"
        case .stopping: return "останавливается…"
        case .stopped: return "остановлен"
        case .exited(0): return "готово · \(duration(from: session.startedAt, to: session.finishedAt ?? now))"
        case .exited(let code): return "ошибка · код \(code)"
        case .failed: return "не запустился"
        }
    }

    private func duration(from start: Date?, to end: Date) -> String {
        guard let start else { return "" }
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)с" }
        if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private func color(_ state: RunState) -> Color {
        switch state {
        case .running: .green
        case .stopping: .orange
        case .exited(0): .blue
        case .exited, .failed: .red
        case .idle, .stopped: .secondary
        }
    }
}
