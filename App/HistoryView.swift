import AppKit
import SwiftUI
import LocalFlowCore

/// Every dictation, newest first: time, app it was pasted into, cleaned text, raw transcript on demand.
struct HistoryView: View {
    @ObservedObject var controller: AppController
    @State private var query = ""
    @State private var expanded: Set<UUID> = []
    @State private var confirmClear = false
    @State private var copiedID: UUID?

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return controller.history }
        return controller.history.filter { $0.cleaned.lowercased().contains(q) || $0.raw.lowercased().contains(q) || ($0.app ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search dictations")
                Spacer()
                Text(countLabel).font(.callout).foregroundStyle(.secondary)
                Button("Refresh") { controller.reloadHistory() }
                Button("Clear All…") { confirmClear = true }
                    .disabled(controller.history.isEmpty)
            }
            .padding(12)
            Divider()
            if !controller.config.historyEnabled {
                offState
            } else if controller.history.isEmpty {
                emptyState
            } else {
                List(filtered) { entry in
                    HistoryRow(entry: entry,
                               expanded: expanded.contains(entry.id),
                               copied: copiedID == entry.id,
                               onToggleRaw: { toggle(entry.id) },
                               onCopy: { controller.copyToClipboard(entry.cleaned); flashCopied(entry.id) },
                               onDelete: { controller.deleteHistory(id: entry.id) })
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("Stored locally in history.jsonl. Nothing leaves this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal File") { controller.revealHistoryFile() }.controlSize(.small)
                Button("Privacy Settings…") { controller.showSettings(tab: .privacy) }.controlSize(.small)
            }
            .padding(10)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            controller.reloadHistory()
        }
        .confirmationDialog("Delete all \(controller.history.count) dictations?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { controller.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This empties history.jsonl. It cannot be undone.")
        }
    }

    private var countLabel: String {
        let n = controller.history.count
        if query.isEmpty { return n == 1 ? "1 dictation" : "\(n) dictations" }
        return "\(filtered.count) of \(n)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "mic").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Nothing yet").font(.title3)
            Text("Hold Right Option and say something. Every dictation shows up here, with the text that was pasted.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var offState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "eye.slash").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("History is off").font(.title3)
            Text("Turn it on to keep a local record of what you dictate.").font(.callout).foregroundStyle(.secondary)
            Button("Turn On History") { controller.update { $0.historyEnabled = true } }
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func flashCopied(_ id: UUID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedID == id { copiedID = nil } }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let expanded: Bool
    let copied: Bool
    let onToggleRaw: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: entry.ts)).font(.caption).foregroundStyle(.secondary)
                if let app = entry.app, !app.isEmpty {
                    Text(app).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if let s = entry.seconds { Text(String(format: "%.0f s", s)).font(.caption).foregroundStyle(.secondary) }
                if entry.pasted == false { Text("copied only").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button(copied ? "Copied" : "Copy") { onCopy() }.controlSize(.small)
                    .accessibilityLabel("Copy dictation")
                Button(expanded ? "Hide Raw" : "Raw") { onToggleRaw() }.controlSize(.small)
                    .disabled(entry.raw.isEmpty || entry.raw == entry.cleaned)
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .controlSize(.small).accessibilityLabel("Delete dictation")
            }
            Text(entry.cleaned)
                .textSelection(.enabled)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if expanded {
                Text(entry.raw)
                    .textSelection(.enabled)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 6)
    }
}
