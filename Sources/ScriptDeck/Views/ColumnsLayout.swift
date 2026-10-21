import AppKit
import SwiftUI

/// Свои колонки вместо NavigationSplitView: плавающий сайдбар macOS 26 не сочетается с панелью вкладок.
struct ColumnsLayout: View {
    @Environment(ProjectStore.self) private var store
    let onAddWorkspace: () -> Void

    @AppStorage("projectsColumnWidth") private var projectsWidth: Double = 230
    @AppStorage("scriptsColumnWidth") private var scriptsWidth: Double = 280

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = store.currentWorkspace, workspace.isGroup {
                ProjectsColumn(workspace: workspace)
                    .frame(width: projectsWidth)
                    .background(Theme.projectsColumn)
                ColumnResizer(width: $projectsWidth, range: 170...380)
            }
            ScriptsColumn(workspace: store.currentWorkspace, onAddWorkspace: onAddWorkspace)
                .frame(width: scriptsWidth)
                .background(Theme.scriptsColumn)
            ColumnResizer(width: $scriptsWidth, range: 220...460)
            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Тонкий разделитель колонок, за который можно потянуть.
private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered || startWidth != nil ? Theme.accent.opacity(0.6) : Theme.separator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovered = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .zIndex(1)
    }
}
