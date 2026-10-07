import AppKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Text(controller.statusLine)
        if controller.modelsMissing && controller.downloadProgress == nil {
            Button("Download Models (~2.9 GB, one time)…") { controller.downloadModels() }
        }
        Divider()
        Toggle("Cleanup", isOn: Binding(get: { controller.config.cleanupEnabled }, set: { _ in controller.toggleCleanup() }))
        Toggle("Paste Raw Transcript Instead", isOn: Binding(get: { controller.config.pasteRawTranscript }, set: { _ in controller.togglePasteRaw() }))
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Open Config") { controller.openConfig() }
        if controller.config.historyEnabled {
            Button("Open History") { controller.openHistory() }
        }
        Button("Open Log") { controller.openLog() }
        Toggle("Launch at Login", isOn: Binding(get: { controller.launchAtLogin }, set: { _ in controller.toggleLaunchAtLogin() }))
        Button("Reload Config") { controller.reloadConfig() }
        Divider()
        Button("Quit LocalFlow") { controller.quit() }
            .keyboardShortcut("q")
    }
}

enum MenuBarIcon {
    @MainActor
    static func image(for state: AppController.IconState) -> NSImage {
        let (name, color): (String, NSColor?) = switch state {
        case .idle: ("mic", nil)
        case .recording: ("mic.fill", .systemRed)
        case .processing: ("waveform", .systemOrange)
        }
        var cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")!.withSymbolConfiguration(cfg)!
        img.isTemplate = (color == nil)
        return img
    }
}
