import AppKit
import SwiftUI

/// Лог на NSTextView: быстрый на тысячах строк, нормальное выделение/копирование и ⌘F из коробки.
struct LogTextView: NSViewRepresentable {
    let session: RunSession?
    let lineCount: Int
    let rebuildToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.background
        scrollView.borderType = .noBorder
        SubtleScroller.install(on: scrollView)

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Palette.background
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = ANSIRenderer.regularFont
        textView.selectedTextAttributes = [.backgroundColor: Palette.accent.withAlphaComponent(0.35)]
        textView.linkTextAttributes = [
            .foregroundColor: Palette.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.layoutManager?.allowsNonContiguousLayout = true

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(session: session, rebuildToken: rebuildToken)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var sessionKey: ScriptKey?
        private var rebuildToken = -1
        private var appendedCount = 0

        private static let newline = NSAttributedString(string: "\n", attributes: [.font: ANSIRenderer.regularFont])

        func sync(session: RunSession?, rebuildToken: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let lines = session?.lines ?? []

            let needsRebuild = session?.key != sessionKey || rebuildToken != self.rebuildToken || lines.count < appendedCount
            if needsRebuild {
                sessionKey = session?.key
                self.rebuildToken = rebuildToken
                storage.setAttributedString(join(lines[...]))
                appendedCount = lines.count
                scrollToBottom()
                return
            }

            guard lines.count > appendedCount else { return }
            let wasAtBottom = isAtBottom
            let chunk = NSMutableAttributedString()
            if storage.length > 0 { chunk.append(Self.newline) }
            chunk.append(join(lines[appendedCount...]))
            storage.append(chunk)
            appendedCount = lines.count
            if wasAtBottom { scrollToBottom() }
        }

        private func join(_ lines: ArraySlice<NSAttributedString>) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for (offset, line) in lines.enumerated() {
                if offset > 0 { result.append(Self.newline) }
                result.append(line)
            }
            return result
        }

        private var isAtBottom: Bool {
            guard let scrollView, let documentView = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= documentView.bounds.height - 40
        }

        private func scrollToBottom() {
            guard let textView else { return }
            textView.scrollToEndOfDocument(nil)
        }
    }
}
