import SwiftUI
import AppKit

@main
struct SpaceMongerApp: App {
    var body: some Scene {
        WindowGroup("SpaceMonger for Mac") {
            ContentView()
                .background {
                    InitialWindowMaximizer()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Remove "New Window" — this is a single-window utility
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Expands the first window to the screen's usable area while keeping the title bar,
/// menu bar, Dock, and standard resize controls available.
private struct InitialWindowMaximizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InitialWindowMaximizingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class InitialWindowMaximizingView: NSView {
    private var hasMaximized = false

    // This is only a window-lifecycle observer. It must never consume clicks intended
    // for SwiftUI controls layered in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasMaximized, let window else { return }
        hasMaximized = true

        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
