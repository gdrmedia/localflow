import AppKit
import SwiftUI
import UserNotifications

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            MenuBarLabel(controller: controller)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(controller: controller)
        }

        Window("LocalFlow History", id: "history") {
            HistoryView(controller: controller)
        }
        .defaultSize(width: 760, height: 560)
    }
}

/// Status-item label; also the one always-alive SwiftUI view that can call `openSettings`.
struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: controller.icon))
            .onChange(of: controller.settingsRequests) { _, _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .onChange(of: controller.historyRequests) { _, _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppController.shared.start()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
