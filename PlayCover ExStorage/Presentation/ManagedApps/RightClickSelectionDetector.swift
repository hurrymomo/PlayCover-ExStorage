import SwiftUI

struct RightClickSelectionDetector: NSViewRepresentable {
    let isEnabled: Bool
    let onLeftMouseDown: () -> Void
    let onRightClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onLeftMouseDown: onLeftMouseDown, onRightClick: onRightClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observedView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onLeftMouseDown = onLeftMouseDown
        context.coordinator.onRightClick = onRightClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onLeftMouseDown: () -> Void
        var onRightClick: () -> Void
        weak var observedView: NSView?
        private var monitor: Any?
        private var isReplayingRightClick = false

        init(isEnabled: Bool, onLeftMouseDown: @escaping () -> Void, onRightClick: @escaping () -> Void) {
            self.isEnabled = isEnabled
            self.onLeftMouseDown = onLeftMouseDown
            self.onRightClick = onRightClick
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = observedView,
                      event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point) else { return event }
                guard isEnabled else { return event }
                if event.type == .leftMouseDown {
                    if event.clickCount == 1 {
                        onLeftMouseDown()
                    }
                    return event
                }
                if isReplayingRightClick {
                    isReplayingRightClick = false
                    return event
                }
                onRightClick()
                // Let SwiftUI commit the selection before it constructs the context menu.
                // Replaying the same event on the next run-loop turn avoids replacing menu
                // items while AppKit is already presenting them.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    isReplayingRightClick = true
                    NSApp.postEvent(event, atStart: true)
                }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}
