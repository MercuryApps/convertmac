import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case trim = "Trim & Crop"
        case subtitles = "Subtitles"
        case tags = "Tags"
        var id: String { rawValue }
    }

    @ObservedObject var item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .trim

    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var playhead: Double = 0
    @State private var cropOn = false
    @State private var crop = NormalizedRect.full
    @State private var aspect: CropAspect = .free
    @State private var audioTrack = 0
    @State private var detecting = false

    @State private var subtitleURL: URL?
    @State private var burnSubtitles = false
    @State private var subtitleStream = 0

    @State private var tags = MediaTags()

    @StateObject private var frames = FrameLoader()

    private var duration: Double { item.info?.duration ?? 0 }
    private var displaySize: (width: Int, height: Int) { item.info?.displaySize ?? (16, 9) }
    private var hasPicture: Bool { !(item.info?.videoStreams.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(16)
            Divider()

            Group {
                switch tab {
                case .trim: trimTab
                case .subtitles: subtitlesTab
                case .tags: tagsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button("Reset All") { resetAll() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 820, height: 640)
        .onAppear(perform: load)
    }

    private var availableTabs: [Tab] {
        hasPicture ? Tab.allCases : [.trim, .tags]
    }

    private var trimTab: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if hasPicture {
                    GeometryReader { geo in
                        let fit = fitRect(in: geo.size)
                        ZStack(alignment: .topLeading) {
                            if let img = frames.frame {
                                Image(nsImage: img)
                                    .resizable()
                                    .frame(width: fit.width, height: fit.height)
                                    .offset(x: fit.minX, y: fit.minY)
                            } else {
                                ProgressView()
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                            if cropOn {
                                CropOverlay(crop: $crop, aspect: aspect.ratio(for: displaySize), frame: fit)
                            }
                        }
                    }
                    .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Audio file — trim it using the timeline below").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            TimelineView(start: $start, end: $end, playhead: $playhead, duration: duration, strip: frames.strip)
                .frame(height: 56)
                .onChange(of: playhead) { _, t in requestFrame(t) }

            HStack(spacing: 14) {
                timeField("Start", value: $start, range: 0...max(0, end - 0.1))
                Button { start = min(playhead, end - 0.1) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Set start to the playhead")
                Spacer()
                Text("\(Fmt.timestamp(playhead)) · clip \(Fmt.duration(max(0, end - start)))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button { end = max(playhead, start + 0.1) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Set end to the playhead")
                timeField("End", value: $end, range: min(duration, start + 0.1)...max(duration, 0.1))
            }

            HStack(spacing: 12) {
                if hasPicture {
                    Toggle("Crop", isOn: $cropOn.animation())
                        .toggleStyle(.switch)
                    Picker("Aspect", selection: $aspect) {
                        ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .disabled(!cropOn)
                    .onChange(of: aspect) { _, a in applyAspect(a) }
                    Button {
                        detectBars()
                    } label: {
                        if detecting { ProgressView().controlSize(.small) } else { Text("Remove Black Bars") }
                    }
                    .disabled(detecting)
                    if cropOn {
                        Text(verbatim: "\(Int(Double(displaySize.width) * crop.width))×\(Int(Double(displaySize.height) * crop.height))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let tracks = item.info?.audioStreams, tracks.count > 1 {
                    Picker("Audio", selection: $audioTrack) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in Text(t.trackLabel).tag(i) }
                        Divider()
                        Text("All tracks").tag(-1)
                    }
                    .frame(maxWidth: 260)
                }
            }
        }
        .padding(16)
    }

    private func timeField(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TimeTextField(value: value, range: range)
                .frame(width: 92)
        }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let ar = Double(displaySize.width) / Double(max(1, displaySize.height))
        var w = size.width, h = w / ar
        if h > size.height { h = size.height; w = h * ar }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func applyAspect(_ a: CropAspect) {
        guard let r = a.ratio(for: displaySize) else { return }
        var w = 1.0, h = 1.0
        if r > 1 { h = 1 / r } else { w = r }
        crop = NormalizedRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func detectBars() {
        guard let ffmpeg = FFmpegToolkit.shared.ffmpegURL else { return }
        detecting = true
        let url = item.url, dur = duration, size = displaySize
        Task {
            let rect = await MediaProbe.detectBlackBars(url, ffmpeg: ffmpeg, duration: dur, size: size)
            detecting = false
            if let rect, !rect.isFull {
                aspect = .free
                crop = rect
                cropOn = true
            } else {
                let a = NSAlert()
                a.messageText = "No black bars found"
                a.informativeText = "This video already fills the whole frame."
                a.runModal()
            }
        }
    }

    private func requestFrame(_ t: Double) {
        guard hasPicture, let ffmpeg = FFmpegToolkit.shared.ffmpegURL else { return }
        frames.request(url: item.url, ffmpeg: ffmpeg, time: t)
    }

    private var subtitlesTab: some View {
        Form {
            Section("Subtitle file") {
                if let url = subtitleURL {
                    LabeledContent(url.lastPathComponent) {
                        Button("Remove") { subtitleURL = nil }
                    }
                } else {
                    LabeledContent("No file added") {
                        Button("Add Subtitle File…") { chooseSubtitle() }
                    }
                }
                Text("Supports SRT, ASS, SSA and WebVTT. It's added as a subtitle track you can turn on and off, or burned into the picture below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Burn in") {
                Toggle(isOn: $burnSubtitles) {
                    Text("Burn subtitles into the video")
                    Text("Always visible, on any player. Can't be turned off later.")
                }
                if burnSubtitles {
                    let embedded = item.info?.subtitleStreams ?? []
                    if subtitleURL != nil {
                        LabeledContent("Using", value: subtitleURL!.lastPathComponent)
                    } else if embedded.isEmpty {
                        Text("Add a subtitle file above — this video has no subtitle tracks.")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Track", selection: $subtitleStream) {
                            ForEach(Array(embedded.enumerated()), id: \.offset) { i, s in Text(s.trackLabel).tag(i) }
                        }
                    }
                }
            }
            if let embedded = item.info?.subtitleStreams, !embedded.isEmpty {
                Section("Tracks in this video") {
                    ForEach(embedded) { s in
                        Text(s.trackLabel).font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = item.url.deletingLastPathComponent()
        if panel.runModal() == .OK { subtitleURL = panel.url }
    }

    private var tagsTab: some View {
        Form {
            Section {
                TextField("Title", text: $tags.title)
                TextField("Artist", text: $tags.artist)
                TextField("Album", text: $tags.album)
                TextField("Album artist", text: $tags.albumArtist)
                HStack {
                    TextField("Year", text: $tags.year)
                    TextField("Track", text: $tags.track)
                }
                TextField("Genre", text: $tags.genre)
                TextField("Comment", text: $tags.comment)
            } footer: {
                Text("Tags are written to the converted file. Clear a field to remove it.")
                    .foregroundStyle(.secondary)
            }
            Section("Artwork") {
                HStack(spacing: 14) {
                    artworkPreview
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Choose Image…") { chooseCover() }
                        if tags.coverURL != nil || (item.info?.coverArt != nil && !tags.removeCover) {
                            Button("Remove Artwork") {
                                tags.coverURL = nil
                                tags.removeCover = true
                            }
                        }
                        Text("Artwork is saved in MP3, M4A and FLAC files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var artworkPreview: some View {
        if let url = tags.coverURL, let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else if !tags.removeCover, item.info?.coverArt != nil, let thumb = item.thumbnail {
            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            tags.coverURL = url
            tags.removeCover = false
        }
    }

    private func load() {
        start = item.trimStart ?? 0
        end = item.trimEnd ?? duration
        playhead = start
        if let c = item.crop, !c.isFull { crop = c; cropOn = true }
        audioTrack = item.audioTrack
        subtitleURL = item.subtitleURL
        burnSubtitles = item.burnSubtitles
        subtitleStream = item.subtitleStream
        tags = item.tags
        if !hasPicture && tab == .subtitles { tab = .trim }
        guard hasPicture, let ffmpeg = FFmpegToolkit.shared.ffmpegURL else { return }
        frames.request(url: item.url, ffmpeg: ffmpeg, time: playhead)
        frames.loadStrip(url: item.url, ffmpeg: ffmpeg, duration: duration)
    }

    private func resetAll() {
        start = 0
        end = duration
        cropOn = false
        crop = .full
        aspect = .free
        audioTrack = 0
        subtitleURL = nil
        burnSubtitles = false
        subtitleStream = 0
        tags = MediaTags.from(item.info?.tags ?? [:])
    }

    private func save() {
        item.trimStart = start > 0.05 ? start : nil
        item.trimEnd = duration > 0 && end < duration - 0.05 ? end : nil
        item.crop = cropOn && !crop.isFull ? crop : nil
        item.audioTrack = audioTrack
        item.subtitleURL = subtitleURL
        item.burnSubtitles = burnSubtitles && (subtitleURL != nil || !(item.info?.subtitleStreams.isEmpty ?? true))
        item.subtitleStream = subtitleStream
        item.tags = tags
        item.tagsEdited = tags != MediaTags.from(item.info?.tags ?? [:])
        dismiss()
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, wide, vertical, square, classic, cinema
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return "Freeform"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .classic: return "4:3"
        case .cinema: return "2.39:1"
        }
    }

    func ratio(for size: (width: Int, height: Int)) -> Double? {
        let target: Double
        switch self {
        case .free: return nil
        case .wide: target = 16.0 / 9
        case .vertical: target = 9.0 / 16
        case .square: target = 1
        case .classic: target = 4.0 / 3
        case .cinema: target = 2.39
        }
        return target / (Double(size.width) / Double(max(1, size.height)))
    }
}

struct CropOverlay: View {
    @Binding var crop: NormalizedRect
    let aspect: Double?
    let frame: CGRect
    @State private var dragStart: NormalizedRect?

    private enum Handle { case move, topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let r = CGRect(x: frame.minX + crop.x * frame.width, y: frame.minY + crop.y * frame.height,
                       width: crop.width * frame.width, height: crop.height * frame.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(frame)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .overlay(thirds)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(.move))

            handle(at: CGPoint(x: r.minX, y: r.minY), .topLeft)
            handle(at: CGPoint(x: r.maxX, y: r.minY), .topRight)
            handle(at: CGPoint(x: r.minX, y: r.maxY), .bottomLeft)
            handle(at: CGPoint(x: r.maxX, y: r.maxY), .bottomRight)
        }
    }

    private var thirds: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func handle(at p: CGPoint, _ h: Handle) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 14, height: 14)
            .offset(x: p.x - 7, y: p.y - 7)
            .gesture(drag(h))
    }

    private func drag(_ h: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let base = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = v.translation.width / frame.width, dy = v.translation.height / frame.height
                crop = adjusted(base, h, dx: dx, dy: dy)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func adjusted(_ b: NormalizedRect, _ h: Handle, dx: Double, dy: Double) -> NormalizedRect {
        let minSize = 0.05
        var x0 = b.x, y0 = b.y, x1 = b.x + b.width, y1 = b.y + b.height
        switch h {
        case .move:
            let nx = min(max(0, b.x + dx), 1 - b.width), ny = min(max(0, b.y + dy), 1 - b.height)
            return NormalizedRect(x: nx, y: ny, width: b.width, height: b.height)
        case .topLeft: x0 += dx; y0 += dy
        case .topRight: x1 += dx; y0 += dy
        case .bottomLeft: x0 += dx; y1 += dy
        case .bottomRight: x1 += dx; y1 += dy
        }
        x0 = max(0, min(x0, x1 - minSize)); x1 = min(1, max(x1, x0 + minSize))
        y0 = max(0, min(y0, y1 - minSize)); y1 = min(1, max(y1, y0 + minSize))
        var r = NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let aspect {
            var h2 = r.width / aspect
            var w2 = r.width
            if h2 > 1 { h2 = 1; w2 = aspect }
            switch h {
            case .topLeft, .topRight: r.y = min(max(0, b.y + b.height - h2), 1 - h2)
            default: r.y = min(r.y, 1 - h2)
            }
            if h == .topLeft || h == .bottomLeft { r.x = max(0, b.x + b.width - w2) }
            r.width = min(w2, 1 - r.x)
            r.height = r.width / aspect
        }
        return r
    }
}

struct TimelineView: View {
    @Binding var start: Double
    @Binding var end: Double
    @Binding var playhead: Double
    let duration: Double
    let strip: [NSImage]

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let x = { (t: Double) -> CGFloat in duration > 0 ? CGFloat(t / duration) * w : 0 }
            let t = { (px: CGFloat) -> Double in duration > 0 ? min(duration, max(0, Double(px / w) * duration)) : 0 }

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if strip.isEmpty {
                        Rectangle().fill(.quaternary)
                    } else {
                        ForEach(Array(strip.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(strip.count), height: h)
                                .clipped()
                        }
                    }
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in playhead = t(v.location.x) })

                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, x(start)), height: h)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: max(0, w - x(end)), height: h)
                    .offset(x: x(end))
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(4, x(end) - x(start)), height: h)
                    .offset(x: x(start))
                    .allowsHitTesting(false)

                Rectangle().fill(Color.white)
                    .frame(width: 2, height: h + 8)
                    .offset(x: x(playhead) - 1, y: -4)
                    .shadow(radius: 1)
                    .allowsHitTesting(false)

                grip(height: h)
                    .offset(x: x(start) - 6)
                    .gesture(DragGesture().onChanged { v in
                        start = min(t(v.location.x), end - 0.1)
                        playhead = start
                    })
                grip(height: h)
                    .offset(x: x(end) - 6)
                    .gesture(DragGesture().onChanged { v in
                        end = max(t(v.location.x), start + 0.1)
                        playhead = end
                    })
            }
        }
    }

    private func grip(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: 12, height: height)
            .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: height * 0.4))
            .contentShape(Rectangle().inset(by: -6))
    }
}

struct TimeTextField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00", text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = Fmt.timestamp(value) }
            .onChange(of: value) { _, v in if !focused { text = Fmt.timestamp(v) } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let t = Fmt.parseTime(text) { value = min(max(t, range.lowerBound), range.upperBound) }
        text = Fmt.timestamp(value)
    }
}

@MainActor
final class FrameLoader: ObservableObject {
    @Published var frame: NSImage?
    @Published var strip: [NSImage] = []
    private var generation = 0
    private var pending: Task<Void, Never>?

    func request(url: URL, ffmpeg: URL, time: Double) {
        generation += 1
        let gen = generation
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let img = await MediaProbe.thumbnail(url, ffmpeg: ffmpeg, at: time, width: 960)
            if gen == generation, let img { frame = img }
        }
    }

    func loadStrip(url: URL, ffmpeg: URL, duration: Double) {
        guard duration > 0 else { return }
        let count = 12
        Task {
            var images = [NSImage?](repeating: nil, count: count)
            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for i in 0..<count {
                    let t = duration * (Double(i) + 0.5) / Double(count)
                    group.addTask { (i, await MediaProbe.thumbnail(url, ffmpeg: ffmpeg, at: t, width: 160)) }
                }
                for await (i, img) in group { images[i] = img }
            }
            strip = images.compactMap { $0 }
        }
    }
}
