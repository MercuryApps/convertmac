import AppKit
import SwiftUI

struct QueueRow: View {
    @ObservedObject var item: MediaItem
    @EnvironmentObject private var queue: QueueManager
    @State private var showEditor = false
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
                    if item.isCropped { badge("crop", "Cropped") }
                    if item.subtitleURL != nil || item.burnSubtitles {
                        badge("captions.bubble", item.burnSubtitles ? "Subtitles burned in" : "Subtitle file added")
                    }
                    if item.tagsEdited { badge("tag", "Tags edited") }
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
        .sheet(isPresented: $showEditor) { EditorView(item: item) }
    }

    private func badge(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.orange)
            .help(help)
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
                if queue.canPause(item) {
                    iconButton(item.status == .paused ? "play.fill" : "pause.fill",
                               help: item.status == .paused ? "Resume" : "Pause") { queue.togglePause(item) }
                    iconButton("stop.fill", help: "Cancel") { queue.cancel(item) }
                } else {
                    ProgressView().controlSize(.small)
                }
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
        if !item.isImage {
            iconButton("slider.horizontal.3", help: "Trim, crop, subtitles & tags") { showEditor = true }
                .disabled(item.info == nil)
        }
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
        if !item.isImage {
            Button("Edit (Trim, Crop, Subtitles, Tags)…") { showEditor = true }.disabled(item.info == nil)
        }
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
                if item.isImage && queue.format.kind != .image {
                    Label("Photos need an image format — pick one in the Image tab", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                } else if queue.settings.mergeFiles && queue.format.kind != .image && !item.isImage {
                    Label("Ready → merged into one \(queue.format.name)", systemImage: "rectangle.stack")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready → \(queue.format.name) (.\(queue.format.ext))", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
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
