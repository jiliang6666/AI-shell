import AppKit
import SwiftUI

struct AIChatScrollTracking {
    private(set) var followsOutput = true
    private var previousHeight: CGFloat?
    private var previousOffset: CGFloat?

    mutating func update(documentHeight: CGFloat, viewportHeight: CGFloat, offset: CGFloat, userDriven: Bool) -> Bool {
        let atBottom = documentHeight - offset - viewportHeight <= 44
        let movedWithinSameContent = previousHeight == documentHeight && previousOffset != offset
        if atBottom || userDriven || movedWithinSameContent { followsOutput = atBottom }
        previousHeight = documentHeight
        previousOffset = offset
        return followsOutput
    }
}

/// Observe the native scroll view so scrolling to read earlier output disables
/// following. Document growth by itself must not be mistaken for user scrolling.
struct AIChatScrollObserver: NSViewRepresentable {
    var onFollowingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onFollowingChanged) }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onAttach = { [weak coordinator = context.coordinator] view in coordinator?.attach(to: view.enclosingScrollView) }
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.onChange = onFollowingChanged
        context.coordinator.attach(to: view.enclosingScrollView)
    }

    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }

    final class Probe: NSView {
        var onAttach: ((Probe) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onAttach?(self) }
    }

    @MainActor
    final class Coordinator {
        var onChange: (Bool) -> Void
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var tracking = AIChatScrollTracking()
        private var liveScrolling = false
        private var lastReported = true

        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        func attach(to scrollView: NSScrollView?) {
            guard let scrollView, self.scrollView !== scrollView else { return }
            detach()
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            _ = tracking.update(documentHeight: scrollView.documentView?.bounds.height ?? 0,
                viewportHeight: scrollView.contentView.bounds.height, offset: scrollView.contentView.bounds.minY, userDriven: false)
            let names: [Notification.Name] = [NSView.boundsDidChangeNotification, NSScrollView.willStartLiveScrollNotification,
                                               NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification]
            for name in names {
                let object: AnyObject = name == NSView.boundsDidChangeNotification ? scrollView.contentView : scrollView
                let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didScroll(name) }
                }
                observers.append(token)
            }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            scrollView = nil
            tracking = AIChatScrollTracking()
            lastReported = true
        }

        private func didScroll(_ notification: Notification.Name) {
            guard let scrollView, let document = scrollView.documentView else { return }
            if notification == NSScrollView.willStartLiveScrollNotification { liveScrolling = true }
            let follows = tracking.update(documentHeight: document.bounds.height,
                viewportHeight: scrollView.contentView.bounds.height,
                offset: scrollView.contentView.bounds.minY, userDriven: liveScrolling)
            if notification == NSScrollView.didEndLiveScrollNotification { liveScrolling = false }
            guard follows != lastReported else { return }
            lastReported = follows
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView, self.scrollView === scrollView else { return }
                self.onChange(follows)
            }
        }
    }
}
