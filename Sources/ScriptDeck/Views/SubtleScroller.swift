import AppKit
import SwiftUI

/// Тонкий полупрозрачный скроллер без дорожки: не спорит с тёмными палитрами.
final class SubtleScroller: NSScroller {
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        10
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Дорожку не рисуем.
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = isHovered ? 7 : 5
        let knobRect = NSRect(x: bounds.maxX - width - 2, y: knob.minY + 2, width: width, height: knob.height - 4)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: NSColor = isDark ? .white : .black
        base.withAlphaComponent(isHovered ? 0.28 : 0.14).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Ставит тонкий скроллер всем NSScrollView внутри view.
    static func apply(in root: NSView) {
        if let scrollView = root as? NSScrollView { install(on: scrollView) }
        for subview in root.subviews { apply(in: subview) }
    }

    static func install(on scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is SubtleScroller) {
            scrollView.verticalScroller = SubtleScroller()
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is SubtleScroller) {
            scrollView.horizontalScroller = SubtleScroller()
        }
    }
}

/// Подкладывается под List: SwiftUI не даёт доступа к его NSScrollView напрямую,
/// поэтому проходим по окну после появления и при смене системного стиля скроллеров.
struct SubtleScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> TunerView { TunerView() }
    func updateNSView(_ nsView: TunerView, context: Context) { nsView.scheduleApply() }

    final class TunerView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Система сбрасывает стиль — возвращаем свой чуть позже неё.
                self?.scheduleApply()
            }
        }

        func scheduleApply() {
            DispatchQueue.main.async { [weak self] in
                guard let contentView = self?.window?.contentView else { return }
                SubtleScroller.apply(in: contentView)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
