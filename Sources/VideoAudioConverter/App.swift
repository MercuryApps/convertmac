import AppKit
import SwiftUI

@main
struct VideoAudioConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = QueueManager.shared
    @StateObject private var toolkit = FFmpegToolkit.shared

    var body: some Scene {
        Window("Video & Audio Converter", id: "main") {
            ContentView()
                .environmentObject(queue)
                .environmentObject(toolkit)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { queue.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Convert") {
                Button(queue.isRunning ? "Stop All" : "Start Converting") {
                    queue.isRunning ? queue.stopAll() : queue.startAll()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(queue.items.isEmpty)
                Divider()
                Button("Clear Finished") { queue.clearFinished() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Clear All") { queue.clearAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(queue)
                .environmentObject(toolkit)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await FFmpegToolkit.shared.refresh() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        QueueManager.shared.add(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard QueueManager.shared.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Conversions are still running"
        alert.informativeText = "Quitting now will cancel them and delete the unfinished files."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        QueueManager.shared.stopAll()
    }
}
