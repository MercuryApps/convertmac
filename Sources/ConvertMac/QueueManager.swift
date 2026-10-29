import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class MediaItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let isImage: Bool
    @Published var info: MediaInfo?
    @Published var thumbnail: NSImage?
    @Published var status: ItemStatus = .analyzing
    @Published var progress: Double = 0
    @Published var eta: Double?
    @Published var speed: Double?
    @Published var outputURL: URL?
    @Published var outputSize: Int64?
    @Published var trimStart: Double?
    @Published var trimEnd: Double?
    @Published var audioTrack = 0
    @Published var crop: NormalizedRect?
    @Published var subtitleURL: URL?
    @Published var burnSubtitles = false
    @Published var subtitleStream = 0
    @Published var tags = MediaTags()
    @Published var tagsEdited = false
    var startedAt: Date?

    init(url: URL) {
        self.url = url
        isImage = MediaItem.isStillImage(url)
    }

    static func isStillImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .gif)
    }

    var name: String { url.lastPathComponent }
    var isAudioOnly: Bool { !isImage && (info.map { $0.videoStreams.isEmpty } ?? false) }
    var isTrimmed: Bool { (trimStart ?? 0) > 0 || trimEnd != nil }
    var isCropped: Bool { crop.map { !$0.isFull } ?? false }
    var hasEdits: Bool { isTrimmed || isCropped || subtitleURL != nil || burnSubtitles || tagsEdited }

    var jobInput: JobInput {
        JobInput(url: url, info: info, trimStart: trimStart, trimEnd: trimEnd, audioTrack: audioTrack,
                 crop: crop, subtitleURL: subtitleURL, burnSubtitles: burnSubtitles,
                 subtitleStream: subtitleStream, tags: tagsEdited ? tags : nil)
    }

    var summary: String {
        guard let info else { return url.deletingLastPathComponent().path }
        if isImage {
            var parts: [String] = []
            if let d = info.displaySize { parts.append("\(d.width)×\(d.height)") }
            parts.append(url.pathExtension.uppercased())
            if info.size > 0 { parts.append(Fmt.bytes(info.size)) }
            return parts.joined(separator: " · ")
        }
        var parts = [Fmt.duration(info.duration)]
        if let v = info.primaryVideo {
            if let d = info.displaySize { parts.append("\(d.width)×\(d.height)") }
            parts.append(v.codec.uppercased())
            if let f = v.fps, f > 0, f < 500 { parts.append("\(Fmt.fps(f)) fps") }
            if v.isHDR { parts.append(v.colorTransfer == "arib-std-b67" ? "HDR (HLG)" : "HDR") }
        } else if let a = info.audioStreams.first {
            parts.append(a.codec.uppercased())
            if let sr = a.sampleRate { parts.append(String(format: "%.1f kHz", Double(sr) / 1000)) }
            if let ch = a.channelLayout ?? a.channels.map({ "\($0) ch" }) { parts.append(ch) }
        }
        if info.audioStreams.count > 1 { parts.append("\(info.audioStreams.count) audio tracks") }
        if !info.subtitleStreams.isEmpty { parts.append("\(info.subtitleStreams.count) subtitle\(info.subtitleStreams.count == 1 ? "" : "s")") }
        if info.size > 0 { parts.append(Fmt.bytes(info.size)) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class QueueManager: ObservableObject {
    static let shared = QueueManager()

    @Published var items: [MediaItem] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var isRunning = false
    @Published private(set) var overallProgress: Double = 0
    @Published var settings: ConversionSettings {
        didSet { saveSettings() }
    }
    @Published private(set) var presets: [UserPreset] = []
    @Published var activePresetID: UUID?

    private let toolkit = FFmpegToolkit.shared
    private var runners: [UUID: FFmpegRunner] = [:]
    private var imageJobs: Set<UUID> = []
    private var mergeMembers: [UUID] = []
    private var reservedOutputs: Set<String> = []
    private var analysisQueue: [MediaItem] = []
    private var analysisInFlight = 0
    private var activity: NSObjectProtocol?
    private var batchDone: [URL] = []
    private var batchFailed = 0

    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "vob",
        "ts", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "dv", "rm", "rmvb", "divx", "hevc", "h264", "y4m", "gif",
        "mp3", "m4a", "m4b", "m4r", "aac", "wav", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus", "wma", "ac3",
        "eac3", "dts", "amr", "ape", "caf", "mka", "wv", "mp2", "au", "snd", "ra", "tta", "spx",
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif", "jp2", "psd", "dng", "cr2", "nef", "arw",
    ]

    init() {
        Prefs.register()
        let d = UserDefaults.standard
        settings = d.data(forKey: Prefs.settings).flatMap(ConversionSettings.decode) ?? ConversionSettings()
        if let data = d.data(forKey: Prefs.presets),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            presets = raw.compactMap { dict in
                guard let name = dict["name"] as? String,
                      let idString = dict["id"] as? String, let id = UUID(uuidString: idString),
                      let settingsObj = dict["settings"],
                      let settingsData = try? JSONSerialization.data(withJSONObject: settingsObj),
                      let settings = ConversionSettings.decode(settingsData) else { return nil }
                return UserPreset(id: id, name: name, settings: settings)
            }
        }
    }

    var format: OutputFormat { OutputFormat.with(id: settings.formatID) }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Prefs.settings)
        }
    }

    func select(format f: OutputFormat) {
        var s = settings
        s.formatID = f.id
        s.videoCodec = f.defaultVideoCodec
        s.audioCodec = f.defaultAudioCodec
        s.resolution = f.preset.resolution ?? 0
        s.quality = f.preset.quality ?? .high
        s.fps = f.preset.fps ?? 0
        if s.rateControl == .bitrate { s.rateControl = .quality }
        s.audioBitrate = f.preset.audioBitrate ?? f.defaultAudioCodec.defaultBitrate
        s.sampleRate = 0
        s.channels = 0
        if f.kind == .video { s.removeAudio = false }
        settings = s
        activePresetID = nil
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[i].settings = settings
            activePresetID = presets[i].id
        } else {
            let p = UserPreset(name: trimmed, settings: settings)
            presets.append(p)
            activePresetID = p.id
        }
        persistPresets()
    }

    func apply(preset: UserPreset) {
        settings = preset.settings
        activePresetID = preset.id
    }

    func rename(preset: UserPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = presets.firstIndex(of: preset) else { return }
        presets[i].name = trimmed
        persistPresets()
    }

    func delete(preset: UserPreset) {
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        persistPresets()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Prefs.presets)
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose videos, audio files, photos or folders to convert"
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if mediaExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .audiovisualContent) || t.conforms(to: .image) }
        return false
    }

    func add(urls: [URL]) {
        let fm = FileManager.default
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let f as URL in e where Self.isMedia(f) { found.append(f) }
                files += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else {
                files.append(u)
            }
        }
        var existing = Set(items.map { $0.url.standardizedFileURL.path })
        for f in files where !existing.contains(f.standardizedFileURL.path) {
            existing.insert(f.standardizedFileURL.path)
            let item = MediaItem(url: f)
            items.append(item)
            analysisQueue.append(item)
        }
        if items.contains(where: \.isImage) && items.allSatisfy(\.isImage) && format.kind != .image {
            select(format: OutputFormat.with(id: "jpg"))
        }
        pumpAnalysis()
    }

    private func pumpAnalysis() {
        while analysisInFlight < 4, !analysisQueue.isEmpty {
            let item = analysisQueue.removeFirst()
            analysisInFlight += 1
            Task { await analyze(item); analysisInFlight -= 1; pumpAnalysis() }
        }
    }

    private func analyze(_ item: MediaItem) async {
        guard items.contains(where: { $0 === item }) else { return }
        if item.isImage {
            let url = item.url
            let result = await Task.detached { ImageConverter.inspect(url) }.value
            guard let (info, thumb) = result else {
                item.status = .failed("Not a recognized image")
                return
            }
            item.info = info
            item.thumbnail = thumb
            finishAnalysis(item)
            return
        }

        if !toolkit.isAvailable { await toolkit.refresh() }
        guard let probe = toolkit.ffprobeURL, let ffmpeg = toolkit.ffmpegURL else {
            item.status = .failed("FFmpeg is not installed")
            return
        }
        guard let info = await MediaProbe.probe(item.url, ffprobe: probe) else {
            item.status = .failed("Not a recognized audio or video file")
            return
        }
        item.info = info
        item.tags = MediaTags.from(info.tags)
        finishAnalysis(item)

        if !info.streams.contains(where: { $0.type == "video" }) { return }
        let at = info.videoStreams.isEmpty ? 0 : min(info.duration * 0.1, 20)
        item.thumbnail = await MediaProbe.thumbnail(item.url, ffmpeg: ffmpeg, at: at)
    }

    private func finishAnalysis(_ item: MediaItem) {
        if item.status == .analyzing { item.status = isRunning ? .queued : .ready }
        if isRunning { pump() }
        objectWillChange.send()
    }

    func startAll() {
        guard toolkit.isAvailable || format.kind == .image else {
            let a = NSAlert()
            a.messageText = "FFmpeg is required"
            a.informativeText = "Choose the location of FFmpeg in Settings → Engine, or install it with Homebrew (brew install ffmpeg)."
            a.runModal()
            return
        }
        let restartable: (ItemStatus) -> Bool = {
            switch $0 {
            case .ready, .failed, .cancelled, .skipped: return true
            default: return false
            }
        }
        var candidates = items.filter { restartable($0.status) && $0.info != nil }
        if candidates.isEmpty { candidates = items.filter { $0.status == .done } }
        let analyzing = items.contains { $0.status == .analyzing }
        guard !candidates.isEmpty || analyzing else { return }

        for item in candidates { reset(item); item.status = .queued }
        batchDone = []
        batchFailed = 0
        isRunning = true
        if UserDefaults.standard.bool(forKey: Prefs.preventSleep) {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Converting media")
        }
        requestNotificationPermission()

        let mergeable = candidates.filter { !$0.isImage }
        if settings.mergeFiles && format.kind != .image && mergeable.count >= 2 && !analyzing {
            startMerge(mergeable)
        }
        pump()
    }

    func stopAll() {
        isRunning = false
        for item in items where item.status == .queued { item.status = .ready }
        for r in runners.values { r.cancel() }
        endBatchState()
    }

    private func reset(_ item: MediaItem) {
        item.progress = 0
        item.eta = nil
        item.speed = nil
        item.outputSize = nil
    }

    private var activeJobs: Int { runners.count + imageJobs.count }

    private func pump() {
        guard isRunning else { return }
        let maxJobs = max(1, UserDefaults.standard.integer(forKey: Prefs.maxConcurrent))
        while activeJobs < maxJobs, let next = items.first(where: { $0.status == .queued }) {
            start(next)
        }
        let waiting = items.contains { $0.status == .queued || $0.status == .analyzing }
        if activeJobs == 0 && !waiting { finishBatch() }
        updateOverall()
    }

    private func makeWorkDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vac-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func start(_ item: MediaItem, softwareOnly: Bool = false) {
        let f = format
        if f.kind == .image {
            startImage(item, format: f)
            return
        }
        if item.isImage {
            item.status = .failed("Photos can only be converted to an image format. Pick one in the Image tab.")
            batchFailed += 1
            return
        }
        guard let ffmpeg = toolkit.ffmpegURL else { item.status = .failed("FFmpeg is not installed"); return }
        let output: URL
        switch resolveOutput(for: item.url, format: f) {
        case .success(let url): output = url
        case .failure(let reason):
            item.status = .skipped(reason.message)
            return
        }
        let workDir = makeWorkDir()
        let inputs = [item.jobInput]
        var s = settings
        if softwareOnly { s.hardwareAcceleration = false }
        let args = CommandBuilder.arguments(inputs: inputs, output: output, settings: s,
                                            format: f, encoders: toolkit.encoders, workDir: workDir)
        let retry: (() -> Void)? = softwareOnly || !Self.usesHardware(args) ? nil : { [weak self] in
            self?.start(item, softwareOnly: true)
        }
        launch(args, ffmpeg: ffmpeg, items: [item], output: output, workDir: workDir,
               expected: CommandBuilder.outputDuration(inputs, s), retrySoftware: retry)
    }

    private static func usesHardware(_ args: [String]) -> Bool {
        args.contains { $0.hasSuffix("_videotoolbox") }
    }

    private func startMerge(_ members: [MediaItem], softwareOnly: Bool = false) {
        guard let ffmpeg = toolkit.ffmpegURL, let first = members.first else { return }
        let f = format
        let base = first.url.deletingPathExtension().lastPathComponent + " (merged)"
        let output: URL
        switch resolveOutput(for: first.url, format: f, baseName: base) {
        case .success(let url): output = url
        case .failure(let reason):
            members.forEach { $0.status = .skipped(reason.message) }
            return
        }
        let workDir = makeWorkDir()
        let inputs = members.map(\.jobInput)
        var s = settings
        if softwareOnly { s.hardwareAcceleration = false }
        let args = CommandBuilder.arguments(inputs: inputs, output: output, settings: s,
                                            format: f, encoders: toolkit.encoders, workDir: workDir)
        mergeMembers = members.map(\.id)
        let retry: (() -> Void)? = softwareOnly || !Self.usesHardware(args) ? nil : { [weak self] in
            self?.startMerge(members, softwareOnly: true)
        }
        launch(args, ffmpeg: ffmpeg, items: members, output: output, workDir: workDir,
               expected: CommandBuilder.outputDuration(inputs, s), retrySoftware: retry)
    }

    private func launch(_ args: [String], ffmpeg: URL, items group: [MediaItem], output: URL, workDir: URL,
                        expected: Double, retrySoftware: (() -> Void)? = nil) {
        guard let lead = group.first else { return }
        let runner = FFmpegRunner(executable: ffmpeg, arguments: args)
        let expected = max(0.001, expected)

        for item in group {
            reset(item)
            item.status = .converting
            item.outputURL = output
            item.startedAt = Date()
        }
        reservedOutputs.insert(output.path)

        runner.onProgress = { [weak self] t, spd in
            guard let self else { return }
            for item in group where item.status.isActive {
                item.progress = min(1, t / expected)
                item.speed = spd
                if let spd, spd > 0 {
                    item.eta = max(0, (expected - t) / spd)
                } else if let started = item.startedAt, item.progress > 0.01 {
                    let elapsed = Date().timeIntervalSince(started)
                    item.eta = elapsed * (1 - item.progress) / item.progress
                }
            }
            self.updateOverall()
        }
        runner.onFinish = { [weak self] status, message, cancelled in
            guard let self else { return }
            try? FileManager.default.removeItem(at: workDir)
            self.runners[lead.id] = nil
            if self.mergeMembers.first == lead.id { self.mergeMembers = [] }
            if status != 0 && !cancelled, let retrySoftware, self.isRunning {
                self.reservedOutputs.remove(output.path)
                try? FileManager.default.removeItem(at: output)
                retrySoftware()
                return
            }
            self.finished(group, output: output, status: status, message: message, cancelled: cancelled)
        }

        do {
            try runner.start()
            runners[lead.id] = runner
        } catch {
            reservedOutputs.remove(output.path)
            try? FileManager.default.removeItem(at: workDir)
            group.forEach { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func startImage(_ item: MediaItem, format f: OutputFormat) {
        if item.isAudioOnly && item.info?.coverArt == nil {
            item.status = .failed("This audio file has no picture to export")
            batchFailed += 1
            return
        }
        let output: URL
        switch resolveOutput(for: item.url, format: f) {
        case .success(let url): output = url
        case .failure(let reason):
            item.status = .skipped(reason.message)
            return
        }
        reset(item)
        item.status = .converting
        item.outputURL = output
        reservedOutputs.insert(output.path)
        imageJobs.insert(item.id)

        let s = settings
        let input = item.jobInput
        let isImage = item.isImage
        let ffmpeg = toolkit.ffmpegURL
        let workDir = makeWorkDir()

        Task {
            let error: String? = await Task.detached {
                var source = input.url
                var crop = input.crop
                var applyGeometry = true
                if !isImage {
                    guard let ffmpeg else { return "FFmpeg is not installed" }
                    let still = workDir.appendingPathComponent("frame.png")
                    let args = CommandBuilder.snapshotArguments(input: input, at: input.start, output: still, settings: s)
                    let r = await ProcessRunner.run(ffmpeg, args)
                    guard r.status == 0, FileManager.default.fileExists(atPath: still.path) else {
                        return String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "Couldn't read a frame"
                    }
                    source = still
                    crop = nil
                    applyGeometry = false
                }
                do {
                    if ImageConverter.canWrite(f.ext) {
                        try ImageConverter.convert(source: source, output: output, ext: f.ext, settings: s,
                                                   crop: crop, applyGeometry: applyGeometry)
                        return nil
                    }
                    guard let ffmpeg else { return "FFmpeg is not installed" }
                    let png = workDir.appendingPathComponent("image.png")
                    try ImageConverter.convert(source: source, output: png, ext: "png", settings: s,
                                               crop: crop, applyGeometry: applyGeometry)
                    let r = await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", png.path,
                                                             "-c:v", "libwebp", "-quality", "\(Int(s.imageQuality * 100))", output.path])
                    return r.status == 0 ? nil : (String(decoding: r.stderr, as: UTF8.self).components(separatedBy: "\n").first ?? "Couldn't save WebP")
                } catch {
                    return error.localizedDescription
                }
            }.value
            try? FileManager.default.removeItem(at: workDir)
            imageJobs.remove(item.id)
            finished([item], output: output, status: error == nil ? 0 : 1, message: error ?? "", cancelled: false)
        }
    }

    private func finished(_ group: [MediaItem], output: URL, status: Int32, message: String, cancelled: Bool) {
        reservedOutputs.remove(output.path)
        let fm = FileManager.default

        if cancelled {
            group.forEach { $0.status = .cancelled; $0.outputURL = nil }
            try? fm.removeItem(at: output)
        } else if status == 0 {
            let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value
            for item in group {
                item.status = .done
                item.progress = 1
                item.eta = nil
                item.outputSize = size
            }
            batchDone.append(output)
        } else {
            group.forEach {
                $0.status = .failed(message.isEmpty ? "FFmpeg exited with code \(status)" : message)
                $0.outputURL = nil
            }
            try? fm.removeItem(at: output)
            batchFailed += 1
        }
        objectWillChange.send()
        pump()
    }

    private func finishBatch() {
        guard isRunning else { return }
        isRunning = false
        endBatchState()

        let defaults = UserDefaults.standard
        let done = batchDone.count
        if done + batchFailed == 0 { return }

        if defaults.bool(forKey: Prefs.sound) {
            NSSound(named: batchFailed > 0 ? "Basso" : "Glass")?.play()
        }
        if defaults.bool(forKey: Prefs.notify) && !NSApp.isActive {
            var body = "\(done) file\(done == 1 ? "" : "s") converted"
            if batchFailed > 0 { body += ", \(batchFailed) failed" }
            postNotification(title: "Conversion finished", body: body)
            NSApp.requestUserAttention(.informationalRequest)
        }
        if defaults.bool(forKey: Prefs.reveal) && !batchDone.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(batchDone)
        }
    }

    private func endBatchState() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        NSApp.dockTile.badgeLabel = nil
        updateOverall()
    }

    private func updateOverall() {
        let batch = items.filter { $0.status == .queued || $0.status.isActive || ($0.status.isFinished && isRunning) }
        overallProgress = batch.isEmpty ? 0 : batch.map { $0.status.isFinished ? 1 : $0.progress }.reduce(0, +) / Double(batch.count)
        let remaining = items.filter { $0.status == .queued || $0.status.isActive }.count
        NSApp.dockTile.badgeLabel = isRunning && remaining > 0 ? "\(remaining)" : nil
    }

    private func runner(for item: MediaItem) -> FFmpegRunner? {
        if let r = runners[item.id] { return r }
        if mergeMembers.contains(item.id), let lead = mergeMembers.first { return runners[lead] }
        return nil
    }

    func cancel(_ item: MediaItem) {
        if let r = runner(for: item) { r.cancel() } else if item.status == .queued { item.status = .ready }
        objectWillChange.send()
    }

    func togglePause(_ item: MediaItem) {
        guard let r = runner(for: item) else { return }
        let members = mergeMembers.contains(item.id) ? items.filter { mergeMembers.contains($0.id) } : [item]
        if r.isPaused {
            r.resume()
            members.forEach { $0.status = .converting }
        } else {
            r.pause()
            members.forEach { $0.status = .paused }
        }
    }

    func canPause(_ item: MediaItem) -> Bool { runner(for: item) != nil }

    func retry(_ item: MediaItem) {
        guard item.info != nil, !item.status.isActive else { return }
        reset(item)
        item.status = .queued
        if !isRunning {
            batchDone = []
            batchFailed = 0
            isRunning = true
        }
        pump()
    }

    func remove(_ item: MediaItem) {
        if item.status.isActive { runner(for: item)?.cancel() }
        analysisQueue.removeAll { $0 === item }
        items.removeAll { $0 === item }
        selection.remove(item.id)
        pump()
    }

    func removeSelected() {
        for item in items where selection.contains(item.id) { remove(item) }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    func clearAll() {
        for r in runners.values { r.cancel() }
        analysisQueue.removeAll()
        items.removeAll()
        selection.removeAll()
    }

    func commandLine(for item: MediaItem) -> String {
        guard let ffmpeg = toolkit.ffmpegURL else { return "ffmpeg not found" }
        let f = format
        let out: URL
        switch resolveOutput(for: item.url, format: f) {
        case .success(let u): out = u
        case .failure: out = item.url.deletingPathExtension().appendingPathExtension(f.ext)
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("vac-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let args: [String]
        if f.kind == .image {
            args = CommandBuilder.snapshotArguments(input: item.jobInput, at: item.jobInput.start,
                                                    output: out.deletingPathExtension().appendingPathExtension("png"), settings: settings)
        } else {
            args = CommandBuilder.arguments(inputs: [item.jobInput], output: out, settings: settings,
                                            format: f, encoders: toolkit.encoders, workDir: workDir)
        }
        return CommandBuilder.shellString(executable: ffmpeg, arguments: args)
    }

    struct OutputError: Error { let message: String }

    func outputFolder(for source: URL) -> URL {
        let d = UserDefaults.standard
        if d.string(forKey: Prefs.outputMode) == "custom", let path = d.string(forKey: Prefs.outputFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return source.deletingLastPathComponent()
    }

    private func resolveOutput(for source: URL, format f: OutputFormat, baseName: String? = nil) -> Result<URL, OutputError> {
        let d = UserDefaults.standard
        let folder = outputFolder(for: source)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(OutputError(message: "Can't create output folder"))
        }
        let suffix = d.string(forKey: Prefs.suffix) ?? ""
        let base = (baseName ?? source.deletingPathExtension().lastPathComponent) + suffix
        let policy = d.string(forKey: Prefs.conflict) ?? "rename"
        let sourcePaths = Set(items.map { $0.url.standardizedFileURL.path })
        let fm = FileManager.default

        func candidate(_ n: Int) -> URL {
            folder.appendingPathComponent(n == 0 ? base : "\(base) (\(n))").appendingPathExtension(f.ext)
        }
        func taken(_ u: URL) -> Bool {
            sourcePaths.contains(u.standardizedFileURL.path) || reservedOutputs.contains(u.path)
        }

        let first = candidate(0)
        if !taken(first) {
            if !fm.fileExists(atPath: first.path) { return .success(first) }
            if policy == "overwrite" { return .success(first) }
            if policy == "skip" { return .failure(OutputError(message: "Skipped · \(first.lastPathComponent) already exists")) }
        }
        var n = 1
        while true {
            let u = candidate(n)
            if !taken(u) && !fm.fileExists(atPath: u.path) { return .success(u) }
            n += 1
        }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private func requestNotificationPermission() {
        guard canNotify, UserDefaults.standard.bool(forKey: Prefs.notify) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
