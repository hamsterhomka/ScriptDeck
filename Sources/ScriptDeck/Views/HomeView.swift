import SwiftUI

/// Домашняя вкладка: всё, что сейчас запущено — в ScriptDeck и вне его, у всех пользователей.
struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @State private var monitor = SystemMonitor.shared

    private var externalGroups: [(user: String, isOwn: Bool, scripts: [ExternalScript])] {
        let grouped = Dictionary(grouping: monitor.scripts, by: \.user)
        return grouped
            .map { (user: $0.key, isOwn: $0.value.first?.isOwn ?? false, scripts: $0.value) }
            .sorted { lhs, rhs in lhs.isOwn != rhs.isOwn ? lhs.isOwn : lhs.user < rhs.user }
    }

    var body: some View {
        let sessions = store.activeSessions
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(sessionCount: sessions.count)

                if !sessions.isEmpty {
                    HomeSection(title: "ScriptDeck", subtitle: "\(sessions.count)") {
                        ForEach(sessions) { session in
                            SessionCard(session: session)
                        }
                    }
                }

                ForEach(externalGroups, id: \.user) { group in
                    HomeSection(
                        title: group.isOwn ? "Вне ScriptDeck" : "Пользователь \(group.user)",
                        subtitle: group.isOwn ? "\(group.user) · \(group.scripts.count)" : "\(group.scripts.count) · остановка с паролем администратора"
                    ) {
                        ForEach(group.scripts) { script in
                            ExternalCard(script: script)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            // Пустое состояние — по центру всего окна, а не колонки контента.
            if sessions.isEmpty, monitor.scripts.isEmpty {
                ContentUnavailableView("Ничего не запущено", systemImage: "moon.zzz",
                                       description: Text("Здесь появятся все скрипты: из ScriptDeck, WebStorm, терминала\nи других пользователей этого Mac"))
                    .allowsHitTesting(false)
            }
        }
        .background(Theme.detailBackground)
        .background(SubtleScrollers())
        .onAppear { monitor.refresh() }
    }

    private func header(sessionCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Запущено")
                    .font(.largeTitle.weight(.semibold))
                Text("\(sessionCount) в ScriptDeck · \(monitor.scripts.count) вне его")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Обновить")
        }
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) { content }
        }
    }
}

private struct CardBackground: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.scriptsColumn)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? Theme.accent.opacity(0.5) : Theme.separator)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SessionCard: View {
    @Environment(ProjectStore.self) private var store
    let session: RunSession

    var body: some View {
        let project = store.project(for: session.key)
        HStack(spacing: 12) {
            StatusDot(state: session.state, hasUnseenError: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.key.scriptName).font(.headline)
                    Text(project?.title ?? "").foregroundStyle(.secondary)
                }
                Text(session.displayCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let url = session.detectedURL {
                PortChip(label: url.port.map { ":\($0)" } ?? url.host() ?? "", url: url)
            }
            Uptime(since: session.startedAt)
            IconButton(systemImage: "arrow.clockwise", help: "Перезапустить") { store.restart(session.key) }
            IconButton(systemImage: "stop.fill", help: "Остановить", tint: .red) { store.stop(session.key) }
                .disabled(session.state == .stopping)
        }
        .modifier(CardBackground())
        .contentShape(Rectangle())
        .onTapGesture { store.reveal(session.key) }
        .help("Открыть лог")
    }
}

private struct ExternalCard: View {
    @Environment(ProjectStore.self) private var store
    let script: ExternalScript

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(script.isOrphan ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(script.name).font(.headline)
                    if let directory = script.directory {
                        Text((directory as NSString).lastPathComponent).foregroundStyle(.secondary)
                    }
                    SourceBadge(script: script)
                }
                Text(script.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let directory = script.directory {
                    Text((directory as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            ForEach(script.ports, id: \.self) { port in
                if let url = script.url(for: port) {
                    PortChip(label: ":\(port)", url: url)
                }
            }
            Uptime(since: script.startedAt)
            if let directory = script.directory {
                IconButton(systemImage: "folder", help: "Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                }
                if script.isOwn, !store.workspaces.contains(where: { directory.hasPrefix($0.path) }) {
                    IconButton(systemImage: "plus.rectangle.on.rectangle", help: "Открыть проект вкладкой") {
                        store.addWorkspace(at: URL(fileURLWithPath: directory))
                    }
                }
            }
            IconButton(systemImage: script.isOwn ? "stop.fill" : "lock.fill",
                       help: script.isOwn ? "Остановить (pid \(script.pid))" : "Остановить — процесс другого пользователя, потребуется пароль администратора",
                       tint: .red) {
                SystemMonitor.shared.stop(script)
            }
        }
        .modifier(CardBackground())
        .help("pid \(script.pid) · \(script.user)")
    }
}

private struct SourceBadge: View {
    let script: ExternalScript

    var body: some View {
        let text: String = {
            if script.isOrphan { return (script.source.map { "\($0) · " } ?? "") + "родитель закрыт" }
            return script.source ?? "терминал"
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(script.isOrphan ? Color.orange : Color.secondary)
            .background((script.isOrphan ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
            .help(script.isOrphan ? "Приложение, которое запустило скрипт, уже закрыто — процесс висит сам по себе" : "Откуда запущен")
    }
}

private struct PortChip: View {
    let label: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(label, systemImage: "safari")
                .font(.caption.weight(.medium).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

private struct Uptime: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(since)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)с" }
        if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        if seconds < 86_400 { return String(format: "%dч %02dм", seconds / 3600, (seconds % 3600) / 60) }
        return "\(seconds / 86_400)д \((seconds % 86_400) / 3600)ч"
    }
}

private struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
