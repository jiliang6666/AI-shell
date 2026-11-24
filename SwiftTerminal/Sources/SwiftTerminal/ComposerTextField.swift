import AppKit
import SwiftUI

/// Chat-composer text view: Return sends, Shift+Return inserts a newline.
/// A real NSTextView is required because SwiftUI's TextField cannot
/// distinguish modifier keys in `onSubmit`, so Shift+Return also submits.
@MainActor
final class ComposerTextView: NSTextView {
    var onReturn: (() -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func insertNewline(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if shift {
            super.insertNewline(sender)
        } else if let onReturn {
            onReturn()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let origin = NSPoint(x: textContainerOrigin.x + 1, y: textContainerOrigin.y)
            (placeholder as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}

/// SwiftUI bridge for `ComposerTextView`.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var disabled: Bool
    var onSubmit: () -> Void

    private let minimumHeight: CGFloat = 62

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            parent.text = view.string
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        let view = ComposerTextView(frame: scrollView.contentView.bounds)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 8)
        view.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.minSize = NSSize(width: 0, height: minimumHeight)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.font = font
        view.textColor = .labelColor
        view.placeholder = placeholder
        view.onReturn = onSubmit
        view.delegate = context.coordinator
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.textArea)
        view.setAccessibilityLabel(placeholder)
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.placeholder = placeholder
        if view.font != font { view.font = font }
        view.onReturn = onSubmit
        view.isEditable = !disabled
        view.isSelectable = true
        view.alphaValue = disabled ? 0.5 : 1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let view = scrollView.documentView as? ComposerTextView,
              let container = view.textContainer else { return nil }
        let horizontalPadding = 2 * (view.textContainerInset.width + container.lineFragmentPadding)
        let verticalPadding = 2 * view.textContainerInset.height
        let lineHeight = view.layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height
        let maximumHeight = max(minimumHeight, ceil(lineHeight * 8 + verticalPadding))
        let draft = text
        let measuredText = draft.last?.isNewline == true ? draft + "\u{200B}" : draft
        let used = (measuredText as NSString).boundingRect(
            with: NSSize(width: max(1, width - horizontalPadding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let height = min(max(ceil(used.height + verticalPadding), minimumHeight), maximumHeight)
        return CGSize(width: width, height: height)
    }
}
