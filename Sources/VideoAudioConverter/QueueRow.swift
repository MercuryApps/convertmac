import AppKit
import SwiftUI

struct QueueRow: View {
    @ObservedObject var item: MediaItem
    @EnvironmentObject private var queue: QueueManager
    @State private var showTrim = false
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isTrimmed {
                        Label(trimLabel, systemImage: "scissors")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                StatusLine(item: item)
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
    }

    private var trimLabel: String {
        let start = Fmt.timestamp(item.trimStart ?? 0)
        let end = item.trimEnd.map(Fmt.timestamp) ?? "end"
        return "\(start)–\(end)"
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch item.status {
            case .converting, .paused:
                iconButton(item.status == .paused ? "play.fill" : "pause.fill",
                           help: item.status == .paused ? "Resume" : "Pause") { queue.togglePause(item) }
                iconButton("stop.fill", help: "Cancel") { queue.cancel(item) }
            case .done:
                iconButton("play.circle", help: "Open converted file") {
                    if let u = item.outputURL { NSWorkspace.shared.open(u) }
                }
                iconButton("magnifyingglass", help: "Show in Finder") {
                    if let u = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                iconButton("arrow.clockwise", help: "Convert again") { queue.retry(item) }
            case .failed, .cancelled, .skipped:
                iconButton("arrow.clockwise", help: "Retry") { queue.retry(item) }
                editButtons
            case .queued:
                iconButton("xmark.circle", help: "Remove from queue") { queue.cancel(item) }
            default:
                editButtons
            }
            if !item.status.isActive {
                iconButton("xmark", help: "Remove") { queue.remove(item) }
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var editButtons: some View {
        iconButton("scissors", help: "Trim & audio track") { showTrim = true }
            .popover(isPresented: $showTrim, arrowEdge: .bottom) { TrimPopover(item: item) }
            .disabled(item.info == nil)
        iconButton("info.circle", help: "Media info") { showInfo = true }
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { MediaInfoPopover(item: item) }
            .disabled(item.info == nil)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder private var contextMenu: some View {
        if let out = item.outputURL, item.status == .done {
            Button("Open Converted File") { NSWorkspace.shared.open(out) }
            Button("Show Converted File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            Divider()
        }
        Button("Open Original") { NSWorkspace.shared.open(item.url) }
        Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Trim & Audio Track…") { showTrim = true }.disabled(item.info == nil)
        Button("Media Info…") { showInfo = true }.disabled(item.info == nil)
        Button("Copy FFmpeg Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(queue.commandLine(for: item), forType: .string)
        }
        .disabled(item.info == nil)
        if case .failed(let msg) = item.status {
            Button("Copy Error Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(msg, forType: .string)
            }
        }
        Divider()
        if item.status.isActive {
            Button("Cancel") { queue.cancel(item) }
        } else {
            Button(item.status == .done ? "Convert Again" : "Convert This File") { queue.retry(item) }
                .disabled(item.info == nil)
            Button("Remove", role: .destructive) { queue.remove(item) }
        }
    }
}

struct StatusLine: View {
    @ObservedObject var item: MediaItem
    @EnvironmentObject private var queue: QueueManager

    var body: some View {
        Group {
            switch item.status {
            case .analyzing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Analyzing…")
                }
                .foregroundStyle(.secondary)
            case .ready:
                Label("Ready → \(queue.format.name) (.\(queue.format.ext))", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            case .queued:
                Label("Waiting…", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .converting, .paused:
                HStack(spacing: 8) {
                    ProgressView(value: item.progress)
                        .frame(maxWidth: 280)
                        .tint(item.status == .paused ? .orange : .accentColor)
                    Text("\(Int(item.progress * 100))%")
                        .monospacedDigit()
                    if item.status == .paused {
                        Text("Paused").foregroundStyle(.orange)
                    } else {
                        if let eta = item.eta { Text("\(Fmt.duration(eta)) left").foregroundStyle(.secondary) }
                        if let s = item.speed, s > 0 { Text(String(format: "%.1f×", s)).foregroundStyle(.secondary) }
                    }
                }
                .monospacedDigit()
            case .done:
                Label(doneText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let msg):
                Label(msg.components(separatedBy: "\n").last ?? msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(msg)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            case .skipped(let msg):
                Label(msg, systemImage: "arrow.uturn.forward")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private var doneText: String {
        var s = "Done"
        if let out = item.outputURL { s += " · \(out.lastPathComponent)" }
        if let size = item.outputSize {
            let original = item.info?.size ?? 0
            s += " · \(Fmt.bytes(size))"
            if original > 0 {
                let pct = Int((1 - Double(size) / Double(original)) * 100)
                if pct > 0 { s += " (\(pct)% smaller)" }
            }
        }
        return s
    }
}

struct ThumbnailView: View {
    @ObservedObject var item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.quaternary)
            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.isAudioOnly ? "waveform" : "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let d = item.info?.duration, d > 0 {
                Text(Fmt.duration(d))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 0.5))
    }
}

struct TrimPopover: View {
    @ObservedObject var item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var startText = ""
    @State private var endText = ""
    @State private var error: String?

    var body: some View {
        let duration = item.info?.duration ?? 0
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim & Tracks").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Start")
                    TextField("0:00", text: $startText).frame(width: 110)
                }
                GridRow {
                    Text("End")
                    TextField(Fmt.timestamp(duration), text: $endText).frame(width: 110)
                }
            }
            Text("Use seconds or h:mm:ss — e.g. 90, 1:30 or 0:01:30.5. Leave End empty to go to the end (\(Fmt.duration(duration))).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let tracks = item.info?.audioStreams, tracks.count > 1 {
                Picker("Audio", selection: $item.audioTrack) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        Text(t.trackLabel).tag(i)
                    }
                    Divider()
                    Text("All tracks (MKV/MP4/MOV)").tag(-1)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Reset") {
                    item.trimStart = nil
                    item.trimEnd = nil
                    item.audioTrack = 0
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(duration: duration) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            startText = item.trimStart.map(Fmt.timestamp) ?? ""
            endText = item.trimEnd.map(Fmt.timestamp) ?? ""
        }
    }

    private func apply(duration: Double) {
        let start = startText.isEmpty ? 0 : Fmt.parseTime(startText)
        let end = endText.isEmpty ? nil : Fmt.parseTime(endText)
        guard let start else { error = "Start time isn't valid"; return }
        if !endText.isEmpty && end == nil { error = "End time isn't valid"; return }
        if let end, end <= start { error = "End must be after start"; return }
        if duration > 0, start >= duration { error = "Start is past the end of the file"; return }
        item.trimStart = start > 0 ? start : nil
        item.trimEnd = end.flatMap { duration > 0 && $0 >= duration ? nil : $0 }
        dismiss()
    }
}

struct MediaInfoPopover: View {
    @ObservedObject var item: MediaItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.headline).lineLimit(2)
                if let info = item.info {
                    infoRow("Container", info.formatLong.isEmpty ? info.formatName : info.formatLong)
                    infoRow("Duration", Fmt.duration(info.duration))
                    infoRow("Size", Fmt.bytes(info.size))
                    if let br = info.bitRate { infoRow("Bitrate", "\(br / 1000) kbps") }
                    Divider()
                    ForEach(info.streams) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(s.type.capitalized) #\(s.index)\(s.isAttachedPic ? " (cover art)" : "")")
                                .font(.subheadline.weight(.semibold))
                            Text(streamDetail(s))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 360, height: 380)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(v).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func streamDetail(_ s: StreamInfo) -> String {
        var p: [String] = [s.codecLong.isEmpty ? s.codec : "\(s.codec) — \(s.codecLong)"]
        if let w = s.width, let h = s.height { p.append("\(w)×\(h)") }
        if let f = s.fps, f > 0, f < 500, s.type == "video" { p.append("\(Fmt.fps(f)) fps") }
        if s.rotation != 0 { p.append("rotated \(s.rotation)°") }
        if let sr = s.sampleRate { p.append("\(sr) Hz") }
        if let c = s.channelLayout ?? s.channels.map({ "\($0) channels" }) { p.append(c) }
        if let b = s.bitRate { p.append("\(b / 1000) kbps") }
        if let l = s.language { p.append("lang: \(l)") }
        if let t = s.title { p.append("“\(t)”") }
        return p.joined(separator: " · ")
    }
}
