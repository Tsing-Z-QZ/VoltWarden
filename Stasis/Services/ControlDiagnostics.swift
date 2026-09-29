import AppKit
import Foundation
import SwiftUI

@MainActor
final class ControlDiagnostics {
    static let shared = ControlDiagnostics()
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Stasis/control.log")
    private var window: NSWindow?
    private let formatter = ISO8601DateFormatter()

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    func record(_ category: String, _ message: String) {
        let text = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 4_000_000 {
            let archive = fileURL.deletingLastPathComponent().appendingPathComponent("control.previous.log")
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.moveItem(at: fileURL, to: archive)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Stasis diagnostic write failed: %@", error.localizedDescription)
        }
    }

    func show() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1020, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            created.title = "Stasis 控制日志"
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: ControlLogView(fileURL: fileURL))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ControlLogView: View {
    let fileURL: URL
    @State private var text = "等待控制日志…"
    @State private var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目标 → 控制命令 → 实际电池状态（最新在上）").font(.headline)
                Spacer()
                Toggle("实时刷新", isOn: $live)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("复制日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .settingsButton()
                Button("打开日志文件夹") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .settingsButton()
            }
            Text(fileURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .padding(16)
        .task {
            while !Task.isCancelled {
                if live {
                    let url = fileURL
                    let latest = await Task.detached(priority: .utility) {
                        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "等待控制日志…" }
                        return contents.split(separator: "\n").suffix(250).reversed().joined(separator: "\n")
                    }.value
                    text = latest
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
