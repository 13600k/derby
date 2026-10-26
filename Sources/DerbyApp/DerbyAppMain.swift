import SwiftUI
import AppKit
import DerbyCore

@main
struct DerbyApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    /// The dashboard is opened by scene id, never found in `NSApp.windows`:
    /// closing it destroys the window, so after a close (or a windowless launch)
    /// there is nothing to bring forward. A `Window` scene, unlike a
    /// `WindowGroup`, fronts the open window instead of adding a second one.
    static let mainWindowID = "main"

    var body: some Scene {
        Window("Derby", id: Self.mainWindowID) {
            RootView()
                .environmentObject(model)
                // Derby's teal accent, so system controls match `.derbyAccent`
                // instead of following the user's macOS accent colour.
                .tint(.derbyAccent)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Copy Derby Endpoint") {
                    model.copyToPasteboard(model.endpoint, label: "Endpoint")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button(model.status.isRunning ? "Restart Gateway" : "Start Gateway") {
                    Task {
                        if model.status.isRunning { await model.restartGateway() }
                        else { await model.startGateway() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop Gateway") {
                    Task { await model.stopGateway() }
                }
                .disabled(!model.status.isRunning)
            }
        }

        MenuBarExtra("Derby", systemImage: menuBarSymbol) {
            MenuBarContent()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarSymbol: String {
        switch model.status {
        case .running: return model.routingPaused ? "pause.circle" : "flag.checkered"
        case .starting: return "clock"
        case .stopped: return "flag.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// Keeps the gateway alive when the last window closes (the whole point of a
/// local gateway is that it keeps serving), unless the user opted out.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Always set, even when no window ever appears. It used to be assigned in
    /// the window's `onAppear`, so on a windowless login-item launch it stayed
    /// nil and the app quit as soon as any transient window closed.
    var model: AppModel { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A destination missing from `groups` would be silently unreachable —
        // the same class of bug as a sidebar whose rows cannot be selected.
        assert(Set(SidebarItem.allGrouped) == Set(SidebarItem.allCases),
               "Every SidebarItem must appear in the sidebar groups or it is unreachable.")
        assert(SidebarItem.allGrouped.count == SidebarItem.allCases.count,
               "A SidebarItem appears in more than one sidebar group.")
        // Start the gateway whether or not a window is shown. A login item is
        // usually launched hidden, which means the WindowGroup's `.task` never
        // runs. Before this, a reboot left the gateway "Stopped" with autoStart on.
        Task { @MainActor in await AppModel.shared.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !(model.config.app.keepRunningWhenWindowClosed && model.config.app.showMenuBarExtra)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let model = self.model
        // Give the listener a moment to close cleanly so the port is released.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await model.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Derby: \(statusText)")
        if model.status.isRunning {
            Text("Endpoint: \(model.endpoint)")
        }
        Divider()

        Button("Open Derby") {
            // Recreates the window if it was closed; see `mainWindowID`.
            openWindow(id: DerbyApplication.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Copy Endpoint") {
            model.copyToPasteboard(model.endpoint, label: "Endpoint")
        }
        .disabled(!model.status.isRunning)

        Divider()

        if model.status.isRunning {
            Button("Restart Gateway") { Task { await model.restartGateway() } }
            Button(model.routingPaused ? "Resume Routing" : "Pause Routing") {
                Task { await model.toggleRoutingPaused() }
            }
            Button("Stop Gateway") { Task { await model.stopGateway() } }
        } else {
            Button("Start Gateway") { Task { await model.startGateway() } }
        }

        Divider()
        Button("Quit Derby") {
            Task {
                await model.shutdown()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        if model.status.isRunning && model.routingPaused { return "Paused" }
        return model.status.displayName
    }
}
