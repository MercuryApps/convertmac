import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var toolkit: FFmpegToolkit
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if toolkit.checked && !toolkit.isAvailable {
                MissingFFmpegBanner()
                Divider()
            }
            Group {
                if queue.items.isEmpty {
                    EmptyDropView(targeted: dropTargeted)
                } else {
                    QueueListView()
                        .overlay {
                            if dropTargeted {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.accentColor, lineWidth: 3)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            BottomBar()
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls: urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .navigationTitle("Video & Audio Converter")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Add Files or Folders…") { queue.presentOpenPanel() }
                } label: {
                    Label("Add Files", systemImage: "plus")
                } primaryAction: {
                    queue.presentOpenPanel()
                }
                .help("Add files or folders (⌘O)")

                Menu {
                    Button("Clear Finished") { queue.clearFinished() }
                    Button("Clear All", role: .destructive) { queue.clearAll() }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(queue.items.isEmpty)
                .help("Clear the list")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Output Settings", systemImage: "sidebar.right")
                }
                .help("Show or hide output settings")
            }
        }
        .inspector(isPresented: $showInspector) {
            SettingsPanel()
                .inspectorColumnWidth(min: 310, ideal: 350, max: 460)
        }
    }

    private var subtitle: String {
        let n = queue.items.count
        return n == 0 ? "Free video & audio converter" : "\(n) file\(n == 1 ? "" : "s") → \(queue.format.name)"
    }
}

struct EmptyDropView: View {
    @EnvironmentObject private var queue: QueueManager
    let targeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "film.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: targeted)
            VStack(spacing: 6) {
                Text("Drop videos or music here")
                    .font(.title2.weight(.semibold))
                Text("MP4, MOV, MKV, AVI, WebM, MP3, FLAC, WAV and hundreds more.\nPick a format on the right, then hit Convert.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                queue.presentOpenPanel()
            } label: {
                Label("Add Files…", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 18).fill(targeted ? Color.accentColor.opacity(0.06) : .clear))
                .padding(24)
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

struct QueueListView: View {
    @EnvironmentObject private var queue: QueueManager

    var body: some View {
        List(selection: $queue.selection) {
            ForEach(queue.items) { item in
                QueueRow(item: item)
                    .tag(item.id)
            }
            .onMove { queue.items.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { queue.removeSelected() }
    }
}

struct BottomBar: View {
    @EnvironmentObject private var queue: QueueManager
    @AppStorage(Prefs.outputMode) private var outputMode = "source"
    @AppStorage(Prefs.outputFolder) private var outputFolder = Prefs.defaultOutputFolder

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Save to", selection: $outputMode) {
                    Text("Same folder as original").tag("source")
                    Text(URL(fileURLWithPath: outputFolder).lastPathComponent).tag("custom")
                }
                .pickerStyle(.inline)
                Divider()
                Button("Choose Folder…") { chooseFolder() }
                if outputMode == "custom" {
                    Button("Show in Finder") {
                        let url = URL(fileURLWithPath: outputFolder)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
            } label: {
                Label(outputMode == "custom" ? "Save to: \(displayFolder)" : "Save to: same folder as original",
                      systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if queue.isRunning {
                ProgressView(value: queue.overallProgress)
                    .frame(width: 180)
                Text("\(Int(queue.overallProgress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !queue.items.isEmpty {
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            Button {
                queue.isRunning ? queue.stopAll() : queue.startAll()
            } label: {
                Label(queue.isRunning ? "Stop" : "Convert", systemImage: queue.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(queue.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(queue.items.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var displayFolder: String {
        (outputFolder as NSString).abbreviatingWithTildeInPath
    }

    private var summary: String {
        let done = queue.items.filter { $0.status == .done }.count
        let failed = queue.items.filter { if case .failed = $0.status { return true }; return false }.count
        var parts = ["\(queue.items.count) file\(queue.items.count == 1 ? "" : "s")"]
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
            outputMode = "custom"
        }
    }
}

struct MissingFFmpegBanner: View {
    @EnvironmentObject private var toolkit: FFmpegToolkit

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("FFmpeg engine not found").font(.headline)
                Text("This app uses the free, open-source FFmpeg. Install it once with Homebrew: `brew install ffmpeg`")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Install in Terminal") { FFmpegInstaller.openInstallScript() }
            Button("Locate…") { FFmpegInstaller.locate(toolkit: toolkit) }
            Button("Check Again") { Task { await toolkit.refresh() } }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.12))
    }
}

@MainActor
enum FFmpegInstaller {
    static func openInstallScript() {
        let script = """
        #!/bin/zsh
        echo "Installing FFmpeg…"
        if ! command -v brew >/dev/null 2>&1; then
          if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
        fi
        if ! command -v brew >/dev/null 2>&1; then
          echo "Homebrew isn't installed. Get it from https://brew.sh, then run: brew install ffmpeg"
          open "https://brew.sh"
          exit 1
        fi
        brew install ffmpeg && echo "\\nDone! Switch back to Video & Audio Converter and click Check Again."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("install-ffmpeg.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func locate(toolkit: FFmpegToolkit) {
        let panel = NSOpenPanel()
        panel.message = "Select the ffmpeg executable (ffprobe must be in the same folder)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: FFmpegToolkit.customPathKey)
            Task { await toolkit.refresh() }
        }
    }
}
