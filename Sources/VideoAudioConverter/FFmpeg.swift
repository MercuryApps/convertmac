import AppKit
import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunner {
    static func run(_ exe: URL, _ args: [String]) async -> ProcessResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8)))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: outData, stderr: errData))
            }
        }
    }
}

@MainActor
final class FFmpegToolkit: ObservableObject {
    static let shared = FFmpegToolkit()
    static let customPathKey = "ffmpegCustomPath"

    @Published private(set) var ffmpegURL: URL?
    @Published private(set) var ffprobeURL: URL?
    @Published private(set) var version = ""
    @Published private(set) var encoders: Set<String> = []
    @Published private(set) var checked = false

    var isAvailable: Bool { ffmpegURL != nil && ffprobeURL != nil }

    func refresh() async {
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: Self.customPathKey), !custom.isEmpty {
            candidates.append(custom)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]

        let fm = FileManager.default
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            ffmpegURL = nil; ffprobeURL = nil; encoders = []; version = ""; checked = true
            return
        }
        let ff = URL(fileURLWithPath: found)
        let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")

        let v = await ProcessRunner.run(ff, ["-hide_banner", "-version"])
        let firstLine = String(decoding: v.stdout, as: UTF8.self).components(separatedBy: "\n").first ?? ""
        let e = await ProcessRunner.run(ff, ["-hide_banner", "-encoders"])

        var names = Set<String>()
        var pastHeader = false
        for line in String(decoding: e.stdout, as: UTF8.self).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("------") { pastHeader = true; continue }
            guard pastHeader else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2 { names.insert(String(cols[1])) }
        }

        ffmpegURL = ff
        ffprobeURL = fm.isExecutableFile(atPath: probe.path) ? probe : nil
        version = firstLine.components(separatedBy: " Copyright").first?
            .replacingOccurrences(of: "ffmpeg version ", with: "") ?? ""
        encoders = names
        checked = true
    }

    func has(_ encoder: String) -> Bool { encoders.contains(encoder) }
}

enum MediaProbe {
    static func probe(_ url: URL, ffprobe: URL) async -> MediaInfo? {
        let r = await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard r.status == 0 else { return nil }
        return MediaInfo.parse(r.stdout)
    }

    static func thumbnail(_ url: URL, ffmpeg: URL, at time: Double) async -> NSImage? {
        let r = await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", Fmt.number(max(0, time)), "-i", url.path,
            "-frames:v", "1", "-vf", "scale=240:-2", "-f", "image2pipe", "-c:v", "mjpeg", "-",
        ])
        guard r.status == 0, !r.stdout.isEmpty else { return nil }
        return NSImage(data: r.stdout)
    }
}

final class FFmpegRunner {
    private let process = Process()
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrText = ""
    private var lastTime: Double = 0
    private var lastSpeed: Double?
    private(set) var cancelled = false
    private(set) var isPaused = false

    var onProgress: (@MainActor (Double, Double?) -> Void)?
    var onFinish: (@MainActor (Int32, String, Bool) -> Void)?

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
    }

    func start() throws {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.consumeProgress(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if !d.isEmpty { self?.appendError(d) }
        }
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = err.fileHandleForReading.readDataToEndOfFile()
            guard let self else { return }
            self.appendError(rest)
            let status = p.terminationStatus
            let message = self.errorSummary
            let wasCancelled = self.cancelled
            Task { @MainActor in self.onFinish?(status, message, wasCancelled) }
        }
        try process.run()
    }

    func pause() {
        guard process.isRunning, !isPaused else { return }
        if process.suspend() { isPaused = true }
    }

    func resume() {
        guard isPaused else { return }
        if process.resume() { isPaused = false }
    }

    func cancel() {
        cancelled = true
        if isPaused { _ = process.resume(); isPaused = false }
        if process.isRunning { process.terminate() }
    }

    private func appendError(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        stderrText += String(decoding: d, as: UTF8.self)
        if stderrText.count > 20_000 { stderrText = String(stderrText.suffix(10_000)) }
    }

    private var errorSummary: String {
        lock.lock(); defer { lock.unlock() }
        let lines = stderrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(4).joined(separator: "\n")
    }

    private func consumeProgress(_ d: Data) {
        lock.lock()
        stdoutBuffer.append(d)
        var report = false
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = line[line.index(after: eq)...]
            switch key {
            case "out_time_us", "out_time_ms":
                if let us = Double(value), us >= 0 { lastTime = us / 1_000_000 }
            case "speed":
                lastSpeed = Double(value.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces))
            case "progress":
                report = true
            default:
                break
            }
        }
        let t = lastTime, s = lastSpeed
        lock.unlock()
        if report { Task { @MainActor in self.onProgress?(t, s) } }
    }
}

struct JobInput {
    let url: URL
    let info: MediaInfo?
    let trimStart: Double?
    let trimEnd: Double?
    let audioTrack: Int
}

enum CommandBuilder {
    private static let mpeg2Rates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    static func resolvedVideoCodec(_ s: ConversionSettings, _ f: OutputFormat) -> VideoCodec {
        f.videoCodecs.contains(s.videoCodec) ? s.videoCodec : f.defaultVideoCodec
    }

    static func resolvedAudioCodec(_ s: ConversionSettings, _ f: OutputFormat) -> AudioCodec {
        f.audioCodecs.contains(s.audioCodec) ? s.audioCodec : f.defaultAudioCodec
    }

    static func arguments(input: JobInput, output: URL, settings s: ConversionSettings,
                          format f: OutputFormat, encoders: Set<String>) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]

        let start = max(0, input.trimStart ?? 0)
        if start > 0 { a += ["-ss", Fmt.number(start)] }
        if let end = input.trimEnd, end > start { a += ["-t", Fmt.number(end - start)] }
        a += ["-i", input.url.path]

        let info = input.info
        let speed = s.playbackSpeed > 0 ? s.playbackSpeed : 1
        let audioStreams = info?.audioStreams ?? []
        let hasAudio = info == nil || !audioStreams.isEmpty

        func audioMap(single: Bool) -> [String] {
            if input.audioTrack < 0 && !single { return ["-map", "0:a?"] }
            let idx = max(0, input.audioTrack)
            if idx < audioStreams.count { return ["-map", "0:\(audioStreams[idx].index)"] }
            return ["-map", "0:a:0?"]
        }

        switch f.kind {
        case .gif:
            a += videoMap(info) + ["-an", "-sn", "-dn"]
            var vf = geometryFilters(s)
            if speed != 1 { vf.append("setpts=PTS/\(Fmt.number(speed))") }
            vf.append("fps=\(max(1, s.gifFPS))")
            if s.gifWidth > 0 { vf.append("scale=\(s.gifWidth):-1:flags=lanczos") }
            vf.append("split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle")
            a += ["-vf", vf.joined(separator: ","), "-loop", "0"]

        case .audio:
            a += audioMap(single: true)
            a += ["-vn", "-sn", "-dn"]
            a += audioArgs(resolvedAudioCodec(s, f), s, f, input, encoders, speed: speed)

        case .video:
            let vcodec = resolvedVideoCodec(s, f)
            let hasVideo = info == nil || !(info?.videoStreams.isEmpty ?? true)
            if hasVideo {
                a += videoMap(info)
                a += videoArgs(vcodec, s, f, input, encoders, speed: speed)
            }
            if !s.removeAudio && hasAudio {
                a += audioMap(single: false)
                a += audioArgs(resolvedAudioCodec(s, f), s, f, input, encoders, speed: speed)
            } else {
                a += ["-an"]
            }
            a += subtitleArgs(s, f, info)
            a += ["-dn"]
        }

        if s.keepMetadata {
            a += ["-map_metadata", "0", "-map_chapters", "0"]
        } else {
            a += ["-map_metadata", "-1", "-map_chapters", "-1"]
        }
        if f.isMP4Family { a += ["-movflags", "+faststart"] }
        if f.ext == "m4r" { a += ["-f", "ipod"] }
        a.append(output.path)
        return a
    }

    private static func videoMap(_ info: MediaInfo?) -> [String] {
        if let v = info?.primaryVideo { return ["-map", "0:\(v.index)"] }
        return ["-map", "0:v:0?"]
    }

    private static func subtitleArgs(_ s: ConversionSettings, _ f: OutputFormat, _ info: MediaInfo?) -> [String] {
        guard s.keepSubtitles, f.supportsSubtitles, let subs = info?.subtitleStreams, !subs.isEmpty else { return ["-sn"] }
        if f.ext == "mkv" { return ["-map", "0:s?", "-c:s", "copy"] }
        let text = subs.filter(\.isTextSubtitle)
        guard !text.isEmpty else { return ["-sn"] }
        return text.flatMap { ["-map", "0:\($0.index)"] } + ["-c:s", "mov_text"]
    }

    private static func geometryFilters(_ s: ConversionSettings) -> [String] {
        var vf: [String] = []
        if s.deinterlace { vf.append("yadif") }
        switch s.rotation {
        case 90: vf.append("transpose=1")
        case 180: vf.append("hflip,vflip")
        case 270: vf.append("transpose=2")
        default: break
        }
        if s.flipHorizontal { vf.append("hflip") }
        if s.flipVertical { vf.append("vflip") }
        return vf
    }

    private static func videoArgs(_ c: VideoCodec, _ s: ConversionSettings, _ f: OutputFormat,
                                  _ input: JobInput, _ enc: Set<String>, speed: Double) -> [String] {
        let srcVideo = input.info?.primaryVideo
        if c == .copy {
            var r = ["-c:v", "copy"]
            if f.isMP4Family, srcVideo?.codec == "hevc" { r += ["-tag:v", "hvc1"] }
            return r
        }

        var r: [String] = []
        var vf = geometryFilters(s)

        var dims = input.info?.displaySize
        if s.rotation == 90 || s.rotation == 270, let d = dims { dims = (d.height, d.width) }
        if s.resolution == -1 {
            let w = max(2, s.customWidth / 2 * 2), h = max(2, s.customHeight / 2 * 2)
            vf.append("scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2")
            vf.append("pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2")
            vf.append("setsar=1")
        } else if s.resolution > 0 {
            let landscape = dims.map { $0.width >= $0.height } ?? true
            vf.append(landscape ? "scale=-2:'min(\(s.resolution),ih)'" : "scale='min(\(s.resolution),iw)':-2")
        } else if let d = dims, d.width % 2 != 0 || d.height % 2 != 0 {
            vf.append("crop=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if speed != 1 { vf.append("setpts=PTS/\(Fmt.number(speed))") }

        let q = s.quality.rawValue
        let kbps = max(100, s.videoBitrate)
        let byBitrate = s.rateControl == .bitrate && c.supportsBitrate
        let hw = c.hardwareEncoder.map { s.hardwareAcceleration && enc.contains($0) } ?? false
        let sp = s.speed.index
        var pix: String? = "yuv420p"

        func bitrate(capped: Bool) -> [String] {
            capped ? ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"] : ["-b:v", "\(kbps)k"]
        }

        switch c {
        case .h264:
            if hw {
                r += ["-c:v", "h264_videotoolbox"]
                r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([75, 65, 55, 45, 35][q])"]
            } else {
                r += ["-c:v", "libx264", "-preset", ["veryfast", "medium", "slow"][sp]]
                r += byBitrate ? bitrate(capped: true) : ["-crf", "\([17, 20, 23, 26, 30][q])"]
            }
        case .hevc:
            if hw {
                r += ["-c:v", "hevc_videotoolbox"]
                r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([72, 62, 52, 44, 36][q])"]
            } else {
                r += ["-c:v", "libx265", "-preset", ["veryfast", "medium", "slow"][sp], "-x265-params", "log-level=error"]
                r += byBitrate ? bitrate(capped: true) : ["-crf", "\([19, 23, 26, 29, 32][q])"]
            }
            if f.isMP4Family { r += ["-tag:v", "hvc1"] }
        case .av1:
            r += ["-c:v", "libsvtav1", "-preset", ["10", "8", "5"][sp]]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-crf", "\([24, 30, 35, 40, 46][q])"]
        case .vp9:
            r += ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", ["5", "3", "1"][sp]]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-crf", "\([24, 31, 34, 38, 44][q])", "-b:v", "0"]
        case .prores:
            if hw {
                r += ["-c:v", "prores_videotoolbox", "-profile:v", ["hq", "hq", "standard", "lt", "proxy"][q]]
                pix = nil
            } else {
                r += ["-c:v", "prores_ks", "-profile:v", "\([3, 3, 2, 1, 0][q])", "-vendor", "apl0"]
                pix = "yuv422p10le"
            }
        case .mpeg4:
            r += ["-c:v", "mpeg4"]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-q:v", "\([2, 3, 5, 8, 12][q])"]
            if f.ext == "avi" { r += ["-vtag", "xvid"] }
        case .mpeg2:
            r += ["-c:v", "mpeg2video"]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-q:v", "\([2, 3, 5, 8, 12][q])"]
        case .wmv:
            r += ["-c:v", "wmv2"]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-q:v", "\([2, 4, 6, 9, 13][q])"]
        case .gif, .copy:
            break
        }

        if let pix { vf.append("format=\(pix)") }
        if !vf.isEmpty { r += ["-vf", vf.joined(separator: ",")] }

        if s.fps > 0 {
            r += ["-r", Fmt.number(s.fps)]
        } else if c == .mpeg2, let src = srcVideo?.fps, !mpeg2Rates.contains(where: { abs($0 - src) < 0.01 }) {
            r += ["-r", "30"]
        }
        return r
    }

    private static func atempoChain(_ speed: Double) -> [String] {
        var s = speed, out: [String] = []
        while s > 2 { out.append("atempo=2"); s /= 2 }
        while s < 0.5 { out.append("atempo=0.5"); s /= 0.5 }
        if abs(s - 1) > 0.0001 { out.append("atempo=\(Fmt.number(s))") }
        return out
    }

    private static func audioArgs(_ c: AudioCodec, _ s: ConversionSettings, _ f: OutputFormat,
                                  _ input: JobInput, _ enc: Set<String>, speed: Double) -> [String] {
        if c == .copy { return ["-c:a", "copy"] }

        var r: [String] = []
        var af: [String] = []
        if speed != 1 { af += atempoChain(speed) }
        if s.volumeDB != 0 { af.append("volume=\(Fmt.number(s.volumeDB))dB") }
        if s.normalize { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }

        let br = ["-b:a", "\(s.audioBitrate)k"]
        let deep = s.bitDepth == 24
        var nativeVorbis = false

        switch c {
        case .aac: r += ["-c:a", "aac"] + br
        case .mp3: r += ["-c:a", "libmp3lame"] + br
        case .opus: r += ["-c:a", "libopus"] + br
        case .vorbis:
            if enc.contains("libvorbis") {
                r += ["-c:a", "libvorbis"] + br
            } else {
                r += ["-c:a", "vorbis", "-strict", "-2"] + br
                nativeVorbis = true
            }
        case .flac: r += ["-c:a", "flac", "-compression_level", "8", "-sample_fmt", deep ? "s32" : "s16"]
        case .alac: r += ["-c:a", "alac", "-sample_fmt", deep ? "s32p" : "s16p"]
        case .pcm: r += ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"]
        case .aiff: r += ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"]
        case .ac3: r += ["-c:a", "ac3"] + br
        case .mp2: r += ["-c:a", "mp2"] + br
        case .wma: r += ["-c:a", "wmav2"] + br
        case .copy: break
        }

        let srcAudio: StreamInfo? = {
            let streams = input.info?.audioStreams ?? []
            let idx = max(0, input.audioTrack)
            return idx < streams.count ? streams[idx] : streams.first
        }()

        var ar = s.sampleRate
        if ar == 0 && s.normalize { ar = srcAudio?.sampleRate ?? 48000 }
        if ar != 0 && !c.sampleRateOptions.contains(ar) { ar = 48000 }
        if ar == 0, let src = srcAudio?.sampleRate {
            if (c == .opus || c == .ac3) && !c.sampleRateOptions.contains(src) { ar = 48000 }
            if let maxRate = c.maxSampleRate, src > maxRate { ar = maxRate }
        }
        if ar > 0 { r += ["-ar", "\(ar)"] }

        if s.channels > 0 {
            r += ["-ac", "\(c.maxChannels.map { min($0, s.channels) } ?? s.channels)"]
        } else if let maxCh = c.maxChannels, (srcAudio?.channels ?? 2) > maxCh || nativeVorbis {
            r += ["-ac", "\(maxCh)"]
        }

        if !af.isEmpty { r += ["-af", af.joined(separator: ",")] }
        return r
    }

    static func shellString(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map { arg in
            let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=+,@%".contains($0) }
            return safe ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
