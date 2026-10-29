import AppKit
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs().tabItem { Label("General", systemImage: "gearshape") }
            OutputPrefs().tabItem { Label("Output", systemImage: "folder") }
            EnginePrefs().tabItem { Label("Engine", systemImage: "cpu") }
        }
        .frame(width: 520, height: 340)
    }
}

private struct GeneralPrefs: View {
    @AppStorage(Prefs.maxConcurrent) private var maxConcurrent = 2
    @AppStorage(Prefs.notify) private var notify = true
    @AppStorage(Prefs.sound) private var sound = true
    @AppStorage(Prefs.reveal) private var reveal = false
    @AppStorage(Prefs.preventSleep) private var preventSleep = true

    var body: some View {
        Form {
            Picker("Simultaneous conversions", selection: $maxConcurrent) {
                ForEach(1...min(8, ProcessInfo.processInfo.activeProcessorCount), id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Notify me when a batch finishes", isOn: $notify)
            Toggle("Play a sound when finished", isOn: $sound)
            Toggle("Show converted files in Finder when finished", isOn: $reveal)
            Toggle("Keep Mac awake while converting", isOn: $preventSleep)
        }
        .formStyle(.grouped)
    }
}

private struct OutputPrefs: View {
    @AppStorage(Prefs.outputMode) private var outputMode = "source"
    @AppStorage(Prefs.outputFolder) private var outputFolder = Prefs.defaultOutputFolder
    @AppStorage(Prefs.suffix) private var suffix = ""
    @AppStorage(Prefs.conflict) private var conflict = "rename"

    var body: some View {
        Form {
            Picker("Save converted files", selection: $outputMode) {
                Text("Next to the original").tag("source")
                Text("In a folder:").tag("custom")
            }
            .pickerStyle(.radioGroup)
            if outputMode == "custom" {
                LabeledContent("Folder") {
                    HStack {
                        Text((outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { choose() }
                    }
                }
            }
            TextField("Add to filename", text: $suffix, prompt: Text("e.g. -converted"))
            Picker("If the file already exists", selection: $conflict) {
                Text("Keep both (add a number)").tag("rename")
                Text("Replace it").tag("overwrite")
                Text("Skip the file").tag("skip")
            }
            Text("Originals are never modified or replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }
}

private struct EnginePrefs: View {
    @EnvironmentObject private var toolkit: FFmpegToolkit
    @AppStorage(FFmpegToolkit.customPathKey) private var customPath = ""

    private let notable: [(String, String)] = [
        ("libx264", "H.264"), ("libx265", "HEVC"), ("h264_videotoolbox", "H.264 hardware"),
        ("hevc_videotoolbox", "HEVC hardware"), ("libsvtav1", "AV1"), ("libvpx-vp9", "VP9"),
        ("prores_ks", "ProRes"), ("libmp3lame", "MP3"), ("libopus", "Opus"), ("libvorbis", "Vorbis"),
    ]

    var body: some View {
        Form {
            LabeledContent("FFmpeg") {
                if let url = toolkit.ffmpegURL {
                    VStack(alignment: .trailing) {
                        Text(toolkit.version.isEmpty ? "Found" : "Version \(toolkit.version)")
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Text("Not found").foregroundStyle(.red)
                }
            }
            LabeledContent("Custom location") {
                HStack {
                    Text(customPath.isEmpty ? "Automatic" : customPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { FFmpegInstaller.locate(toolkit: toolkit) }
                    if !customPath.isEmpty {
                        Button("Reset") {
                            customPath = ""
                            Task { await toolkit.refresh() }
                        }
                    }
                }
            }
            if toolkit.isAvailable {
                LabeledContent("Encoders") {
                    Text(notable.map { "\(toolkit.has($0.0) ? "✓" : "✗") \($0.1)" }.joined(separator: "   "))
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                HStack {
                    Text("Install the free FFmpeg engine to start converting.")
                    Spacer()
                    Button("Install in Terminal") { FFmpegInstaller.openInstallScript() }
                }
            }
            Button("Check Again") { Task { await toolkit.refresh() } }
        }
        .formStyle(.grouped)
    }
}
