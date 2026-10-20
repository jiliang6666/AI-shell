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

    override var intrinsicContentSize: NSSize {
        // Ensure layout with the final width before measuring, otherwise the
        // used rect reflects a stale/zero-width container and the field grows
        // absurdly tall.
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        let used = layoutManager?.usedRect(for: textContainer!).height ?? 0
        let lineHeight = font?.boundingRectForFont.height ?? 16
        let minHeight: CGFloat = 46
        let maxHeight = lineHeight * 8 + textContainerInset.height * 2
        let height = min(max(used + textContainerInset.height * 2, minHeight), maxHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
        }
    }

    func makeNSView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 8)
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
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
        return view
    }

    func updateNSView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.placeholder = placeholder
        view.font = font
        view.onReturn = onSubmit
        view.isEditable = !disabled
        view.isSelectable = true
        view.alphaValue = disabled ? 0.5 : 1
    }
}
