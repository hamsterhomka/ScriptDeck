import SwiftUI
import UniformTypeIdentifiers

/// Вкладки проектов в шапке окна, как в WebStorm.
struct TabBarView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var isImporterPresented: Bool
    @State private var draggedID: String?

    /// Место под «светофор» окна (hiddenTitleBar).
    private let trafficLightsInset: CGFloat = 78

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: trafficLightsInset)

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    HomeTab(isSelected: store.isHomeSelected)

                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 2)

                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        TabItem(workspace: workspace, index: index, isSelected: workspace.id == store.currentWorkspaceID)
                            .opacity(draggedID == workspace.id ? 0.4 : 1)
                            .onDrag {
                                draggedID = workspace.id
                                return NSItemProvider(object: workspace.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(targetID: workspace.id, draggedID: $draggedID, store: store))
                    }

                    Button {
                        isImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TabIconButtonStyle())
                    .help("Открыть папку проекта или мастер-папку  ⌘T")
                }
                .padding(.vertical, 5)
                .padding(.trailing, 8)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
        }
        .frame(height: 40)
        .background {
            Rectangle()
                .fill(Theme.chrome)
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

/// Домашняя вкладка: закрепена слева, не закрывается и не перетаскивается.
private struct HomeTab: View {
    @Environment(ProjectStore.self) private var store
    @State private var monitor = SystemMonitor.shared
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        let total = store.activeSessions.count + monitor.scripts.count
        HStack(spacing: 6) {
            Image(systemName: "house.fill")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            Text("Главная")
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
            if total > 0 {
                Text("\(total)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.selectedTab) : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : .clear))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.selectedTabBorder)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selectHome() }
        .onHover { isHovered = $0 }
        .help("Все запущенные скрипты на этом Mac  ⌘0")
    }
}

private struct TabItem: View {
    @Environment(ProjectStore.self) private var store
    let workspace: Workspace
    let index: Int
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        let running = store.activeSessions(in: workspace).count
        let hasError = store.hasUnseenError(in: workspace)

        HStack(spacing: 7) {
            Image(systemName: workspace.isGroup ? "folder.fill" : "shippingbox.fill")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary)

            Text(workspace.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            if workspace.isGroup {
                Text("\(workspace.projects.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            ZStack {
                if isHovered {
                    Button {
                        store.closeWorkspace(workspace)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TabIconButtonStyle())
                    .help("Закрыть вкладку")
                } else if hasError {
                    Circle().fill(.red).frame(width: 7, height: 7)
                } else if running > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        if running > 1 {
                            Text("\(running)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .frame(minWidth: 16, minHeight: 16)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.selectedTab) : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.selectedTabBorder)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.currentWorkspaceID = workspace.id }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(workspace.path + (index < 9 ? "  ⌘\(index + 1)" : ""))
        .contextMenu {
            Button("Показать в Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.url])
            }
            Button("Открыть в Терминале", systemImage: "terminal") {
                NSWorkspace.shared.open([workspace.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Пересканировать", systemImage: "arrow.clockwise") { store.rescan(workspace) }
            Divider()
            Button("Закрыть вкладку", systemImage: "xmark") { store.closeWorkspace(workspace) }
        }
    }
}

private struct TabIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : (isHovered ? 0.08 : 0)))
            )
            .onHover { isHovered = $0 }
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedID: String?
    let store: ProjectStore

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.snappy(duration: 0.2)) {
            MainActor.assumeIsolated { store.moveWorkspace(draggedID, before: targetID) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}
