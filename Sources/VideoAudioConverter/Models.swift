import Foundation

enum MediaKind: String, Codable {
    case video, audio, gif
}

enum FormatCategory: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    case devices = "Devices"
    var id: String { rawValue }
}

enum QualityLevel: Int, Codable, CaseIterable, Identifiable {
    case best, high, medium, low, smallest
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .best: return "Best"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .smallest: return "Smallest file"
        }
    }
}

enum RateControl: String, Codable, CaseIterable, Identifiable {
    case quality, bitrate
    var id: String { rawValue }
    var label: String { self == .quality ? "Quality" : "Bitrate" }
}

enum EncoderSpeed: String, Codable, CaseIterable, Identifiable {
    case fast, balanced, slow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .slow: return "Slow (smaller file)"
        }
    }
    var index: Int {
        switch self {
        case .fast: return 0
        case .balanced: return 1
        case .slow: return 2
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc, av1, vp9, prores, mpeg4, mpeg2, wmv, gif, copy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "H.265 / HEVC"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .prores: return "Apple ProRes"
        case .mpeg4: return "MPEG-4 (Xvid)"
        case .mpeg2: return "MPEG-2"
        case .wmv: return "WMV"
        case .gif: return "GIF"
        case .copy: return "Copy (no re-encode)"
        }
    }

    var softwareEncoder: String {
        switch self {
        case .h264: return "libx264"
        case .hevc: return "libx265"
        case .av1: return "libsvtav1"
        case .vp9: return "libvpx-vp9"
        case .prores: return "prores_ks"
        case .mpeg4: return "mpeg4"
        case .mpeg2: return "mpeg2video"
        case .wmv: return "wmv2"
        case .gif: return "gif"
        case .copy: return "copy"
        }
    }

    var hardwareEncoder: String? {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        case .prores: return "prores_videotoolbox"
        default: return nil
        }
    }

    var supportsBitrate: Bool { ![.prores, .copy, .gif].contains(self) }
    var hasSpeedPreset: Bool { [.h264, .hevc, .av1, .vp9].contains(self) }
}

enum AudioCodec: String, Codable, CaseIterable, Identifiable {
    case aac, mp3, opus, vorbis, flac, alac, pcm, aiff, ac3, mp2, wma, copy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .vorbis: return "Vorbis"
        case .flac: return "FLAC (lossless)"
        case .alac: return "Apple Lossless"
        case .pcm: return "PCM (WAV)"
        case .aiff: return "PCM (AIFF)"
        case .ac3: return "Dolby Digital (AC-3)"
        case .mp2: return "MP2"
        case .wma: return "WMA"
        case .copy: return "Copy (no re-encode)"
        }
    }

    var isLossless: Bool { [.flac, .alac, .pcm, .aiff].contains(self) }
    var usesBitrate: Bool { !isLossless && self != .copy }
    var supportsBitDepth: Bool { isLossless }

    var maxChannels: Int? {
        switch self {
        case .mp3, .mp2, .wma, .vorbis: return 2
        default: return nil
        }
    }

    var bitrateOptions: [Int] {
        switch self {
        case .ac3: return [192, 256, 384, 448, 640]
        case .opus: return [32, 48, 64, 96, 128, 160, 192, 256]
        case .mp2: return [128, 160, 192, 224, 256, 320, 384]
        default: return [64, 96, 128, 160, 192, 224, 256, 320]
        }
    }

    var defaultBitrate: Int {
        switch self {
        case .ac3: return 448
        case .opus: return 128
        case .mp2: return 224
        case .mp3: return 256
        default: return 192
        }
    }

    var maxSampleRate: Int? {
        switch self {
        case .mp3, .mp2, .wma, .ac3, .opus: return 48000
        default: return nil
        }
    }

    var sampleRateOptions: [Int] {
        switch self {
        case .opus: return [0, 48000, 24000, 16000]
        case .ac3: return [0, 32000, 44100, 48000]
        case .mp3, .mp2, .wma: return [0, 22050, 32000, 44100, 48000]
        default: return [0, 22050, 32000, 44100, 48000, 96000]
        }
    }
}

struct FormatPreset: Hashable {
    var resolution: Int? = nil
    var quality: QualityLevel? = nil
    var audioBitrate: Int? = nil
    var fps: Double? = nil
}

struct OutputFormat: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let category: FormatCategory
    let ext: String
    let kind: MediaKind
    let symbol: String
    let videoCodecs: [VideoCodec]
    let audioCodecs: [AudioCodec]
    var preset = FormatPreset()

    var defaultVideoCodec: VideoCodec { videoCodecs.first ?? (kind == .gif ? .gif : .h264) }
    var defaultAudioCodec: AudioCodec { audioCodecs.first ?? .aac }
    var isMP4Family: Bool { ["mp4", "mov", "m4v", "m4a", "m4r"].contains(ext) }
    var supportsSubtitles: Bool { ["mkv", "mp4", "mov", "m4v"].contains(ext) }

    static func with(id: String) -> OutputFormat {
        all.first { $0.id == id } ?? all[0]
    }

    static let all: [OutputFormat] = [
        OutputFormat(id: "mp4", name: "MP4", detail: "H.264 · plays anywhere", category: .video, ext: "mp4", kind: .video,
                     symbol: "film", videoCodecs: [.h264, .hevc, .av1, .mpeg4, .copy], audioCodecs: [.aac, .mp3, .ac3, .alac, .opus, .copy]),
        OutputFormat(id: "hevc", name: "HEVC", detail: "H.265 · half the size", category: .video, ext: "mp4", kind: .video,
                     symbol: "sparkles.tv", videoCodecs: [.hevc, .h264, .copy], audioCodecs: [.aac, .ac3, .alac, .copy]),
        OutputFormat(id: "mov", name: "MOV", detail: "QuickTime", category: .video, ext: "mov", kind: .video,
                     symbol: "play.rectangle", videoCodecs: [.h264, .hevc, .prores, .copy], audioCodecs: [.aac, .alac, .pcm, .copy]),
        OutputFormat(id: "prores", name: "ProRes", detail: "Editing master", category: .video, ext: "mov", kind: .video,
                     symbol: "slider.horizontal.below.rectangle", videoCodecs: [.prores], audioCodecs: [.pcm, .aac, .alac],
                     preset: FormatPreset(quality: .best)),
        OutputFormat(id: "mkv", name: "MKV", detail: "Matroska", category: .video, ext: "mkv", kind: .video,
                     symbol: "shippingbox", videoCodecs: [.h264, .hevc, .av1, .vp9, .mpeg4, .copy], audioCodecs: [.aac, .opus, .mp3, .flac, .ac3, .vorbis, .copy]),
        OutputFormat(id: "webm", name: "WebM", detail: "VP9 for the web", category: .video, ext: "webm", kind: .video,
                     symbol: "globe", videoCodecs: [.vp9, .av1], audioCodecs: [.opus, .vorbis]),
        OutputFormat(id: "av1", name: "AV1", detail: "Next-gen, tiny files", category: .video, ext: "mp4", kind: .video,
                     symbol: "leaf", videoCodecs: [.av1], audioCodecs: [.aac, .opus]),
        OutputFormat(id: "m4v", name: "M4V", detail: "iTunes / Apple TV app", category: .video, ext: "m4v", kind: .video,
                     symbol: "tv", videoCodecs: [.h264, .hevc], audioCodecs: [.aac, .ac3]),
        OutputFormat(id: "avi", name: "AVI", detail: "Xvid · legacy players", category: .video, ext: "avi", kind: .video,
                     symbol: "opticaldisc", videoCodecs: [.mpeg4, .h264], audioCodecs: [.mp3, .ac3, .pcm]),
        OutputFormat(id: "wmv", name: "WMV", detail: "Windows Media", category: .video, ext: "wmv", kind: .video,
                     symbol: "pc", videoCodecs: [.wmv], audioCodecs: [.wma]),
        OutputFormat(id: "mpg", name: "MPEG", detail: "MPEG-2 · DVD style", category: .video, ext: "mpg", kind: .video,
                     symbol: "opticaldiscdrive", videoCodecs: [.mpeg2], audioCodecs: [.mp2, .ac3]),
        OutputFormat(id: "ts", name: "TS", detail: "Transport stream", category: .video, ext: "ts", kind: .video,
                     symbol: "antenna.radiowaves.left.and.right", videoCodecs: [.h264, .hevc, .mpeg2, .copy], audioCodecs: [.aac, .ac3, .mp2, .copy]),
        OutputFormat(id: "gif", name: "GIF", detail: "Animated image", category: .video, ext: "gif", kind: .gif,
                     symbol: "photo.stack", videoCodecs: [.gif], audioCodecs: []),

        OutputFormat(id: "mp3", name: "MP3", detail: "Universal", category: .audio, ext: "mp3", kind: .audio,
                     symbol: "music.note", videoCodecs: [], audioCodecs: [.mp3], preset: FormatPreset(audioBitrate: 256)),
        OutputFormat(id: "m4a", name: "M4A", detail: "AAC · Apple Music", category: .audio, ext: "m4a", kind: .audio,
                     symbol: "music.note.list", videoCodecs: [], audioCodecs: [.aac], preset: FormatPreset(audioBitrate: 256)),
        OutputFormat(id: "alac", name: "ALAC", detail: "Apple Lossless", category: .audio, ext: "m4a", kind: .audio,
                     symbol: "hifispeaker", videoCodecs: [], audioCodecs: [.alac]),
        OutputFormat(id: "flac", name: "FLAC", detail: "Lossless", category: .audio, ext: "flac", kind: .audio,
                     symbol: "waveform", videoCodecs: [], audioCodecs: [.flac]),
        OutputFormat(id: "wav", name: "WAV", detail: "Uncompressed", category: .audio, ext: "wav", kind: .audio,
                     symbol: "waveform.path", videoCodecs: [], audioCodecs: [.pcm]),
        OutputFormat(id: "aiff", name: "AIFF", detail: "Uncompressed · Apple", category: .audio, ext: "aiff", kind: .audio,
                     symbol: "waveform.path.ecg", videoCodecs: [], audioCodecs: [.aiff]),
        OutputFormat(id: "ogg", name: "OGG", detail: "Vorbis", category: .audio, ext: "ogg", kind: .audio,
                     symbol: "dot.radiowaves.left.and.right", videoCodecs: [], audioCodecs: [.vorbis]),
        OutputFormat(id: "opus", name: "Opus", detail: "Efficient voice & music", category: .audio, ext: "opus", kind: .audio,
                     symbol: "mic", videoCodecs: [], audioCodecs: [.opus], preset: FormatPreset(audioBitrate: 128)),
        OutputFormat(id: "ac3", name: "AC3", detail: "Dolby Digital", category: .audio, ext: "ac3", kind: .audio,
                     symbol: "speaker.wave.3", videoCodecs: [], audioCodecs: [.ac3], preset: FormatPreset(audioBitrate: 448)),
        OutputFormat(id: "wma", name: "WMA", detail: "Windows Media", category: .audio, ext: "wma", kind: .audio,
                     symbol: "pc", videoCodecs: [], audioCodecs: [.wma]),

        OutputFormat(id: "iphone", name: "iPhone", detail: "HEVC · 1080p", category: .devices, ext: "mp4", kind: .video,
                     symbol: "iphone", videoCodecs: [.hevc, .h264], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 1080, quality: .high, audioBitrate: 160)),
        OutputFormat(id: "ipad", name: "iPad", detail: "HEVC · 1440p", category: .devices, ext: "mp4", kind: .video,
                     symbol: "ipad", videoCodecs: [.hevc, .h264], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 1440, quality: .high, audioBitrate: 192)),
        OutputFormat(id: "appletv", name: "Apple TV", detail: "HEVC · 4K", category: .devices, ext: "mp4", kind: .video,
                     symbol: "appletv", videoCodecs: [.hevc, .h264], audioCodecs: [.aac, .ac3],
                     preset: FormatPreset(resolution: 2160, quality: .high, audioBitrate: 256)),
        OutputFormat(id: "android", name: "Android", detail: "H.264 · 1080p", category: .devices, ext: "mp4", kind: .video,
                     symbol: "candybarphone", videoCodecs: [.h264, .hevc], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 1080, quality: .high, audioBitrate: 160)),
        OutputFormat(id: "youtube", name: "YouTube", detail: "H.264 · 1080p · HQ", category: .devices, ext: "mp4", kind: .video,
                     symbol: "play.rectangle.fill", videoCodecs: [.h264, .hevc], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 1080, quality: .best, audioBitrate: 256)),
        OutputFormat(id: "social", name: "Social", detail: "Instagram · TikTok · 30 fps", category: .devices, ext: "mp4", kind: .video,
                     symbol: "person.2", videoCodecs: [.h264], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 1080, quality: .high, audioBitrate: 128, fps: 30)),
        OutputFormat(id: "web", name: "Web", detail: "H.264 · 720p", category: .devices, ext: "mp4", kind: .video,
                     symbol: "network", videoCodecs: [.h264], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 720, quality: .medium, audioBitrate: 128)),
        OutputFormat(id: "email", name: "Small", detail: "Email & chat · 480p", category: .devices, ext: "mp4", kind: .video,
                     symbol: "envelope", videoCodecs: [.h264], audioCodecs: [.aac],
                     preset: FormatPreset(resolution: 480, quality: .low, audioBitrate: 96)),
        OutputFormat(id: "smarttv", name: "Smart TV", detail: "H.264 · 1080p · AC3", category: .devices, ext: "mp4", kind: .video,
                     symbol: "tv.inset.filled", videoCodecs: [.h264, .hevc], audioCodecs: [.ac3, .aac],
                     preset: FormatPreset(resolution: 1080, quality: .high, audioBitrate: 448)),
        OutputFormat(id: "ringtone", name: "Ringtone", detail: "iPhone .m4r · ≤40 s", category: .devices, ext: "m4r", kind: .audio,
                     symbol: "bell", videoCodecs: [], audioCodecs: [.aac], preset: FormatPreset(audioBitrate: 256)),
    ]
}

struct ConversionSettings: Codable, Equatable {
    var formatID = "mp4"

    var videoCodec: VideoCodec = .h264
    var hardwareAcceleration = true
    var rateControl: RateControl = .quality
    var quality: QualityLevel = .high
    var videoBitrate = 5000
    var resolution = 0
    var customWidth = 1920
    var customHeight = 1080
    var fps: Double = 0
    var speed: EncoderSpeed = .balanced

    var audioCodec: AudioCodec = .aac
    var audioBitrate = 192
    var sampleRate = 0
    var channels = 0
    var bitDepth = 16
    var removeAudio = false

    var playbackSpeed: Double = 1
    var rotation = 0
    var flipHorizontal = false
    var flipVertical = false
    var deinterlace = false
    var volumeDB: Double = 0
    var normalize = false

    var gifFPS = 15
    var gifWidth = 480

    var keepSubtitles = true
    var keepMetadata = true
}

struct StreamInfo: Identifiable, Hashable {
    let index: Int
    let type: String
    let codec: String
    let codecLong: String
    let width: Int?
    let height: Int?
    let fps: Double?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let bitRate: Int?
    let language: String?
    let title: String?
    let isAttachedPic: Bool
    let rotation: Int
    var id: Int { index }

    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]
    var isTextSubtitle: Bool { Self.textSubtitleCodecs.contains(codec) }

    var trackLabel: String {
        var parts: [String] = ["#\(index)"]
        if let t = title, !t.isEmpty { parts.append(t) }
        if let l = language, !l.isEmpty, l != "und" { parts.append(l.uppercased()) }
        parts.append(codec.uppercased())
        if let c = channelLayout ?? channels.map({ "\($0) ch" }) { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

struct MediaInfo: Hashable {
    let duration: Double
    let formatName: String
    let formatLong: String
    let size: Int64
    let bitRate: Int?
    let streams: [StreamInfo]

    var videoStreams: [StreamInfo] { streams.filter { $0.type == "video" && !$0.isAttachedPic } }
    var audioStreams: [StreamInfo] { streams.filter { $0.type == "audio" } }
    var subtitleStreams: [StreamInfo] { streams.filter { $0.type == "subtitle" } }
    var primaryVideo: StreamInfo? { videoStreams.first }

    var displaySize: (width: Int, height: Int)? {
        guard let v = primaryVideo, let w = v.width, let h = v.height else { return nil }
        return abs(v.rotation) % 180 == 90 ? (h, w) : (w, h)
    }

    static func parse(_ data: Data) -> MediaInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fmt = obj["format"] as? [String: Any] ?? [:]
        let raw = obj["streams"] as? [[String: Any]] ?? []
        guard !raw.isEmpty else { return nil }

        func dbl(_ v: Any?) -> Double? {
            if let s = v as? String { return Double(s) }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        func int(_ v: Any?) -> Int? { dbl(v).map { Int($0) } }
        func rate(_ v: Any?) -> Double? {
            guard let s = v as? String else { return nil }
            let p = s.split(separator: "/")
            if p.count == 2, let a = Double(p[0]), let b = Double(p[1]) { return b == 0 ? nil : a / b }
            return Double(s)
        }

        var maxStreamDuration = 0.0
        let streams: [StreamInfo] = raw.map { s in
            let tags = s["tags"] as? [String: Any] ?? [:]
            let disp = s["disposition"] as? [String: Any] ?? [:]
            var rot = 0
            if let sd = s["side_data_list"] as? [[String: Any]] {
                for e in sd { if let r = int(e["rotation"]) { rot = r } }
            }
            if rot == 0, let r = int(tags["rotate"]) { rot = r }
            if let d = dbl(s["duration"]) { maxStreamDuration = max(maxStreamDuration, d) }
            let fps = rate(s["avg_frame_rate"]) ?? rate(s["r_frame_rate"])
            return StreamInfo(
                index: int(s["index"]) ?? 0,
                type: s["codec_type"] as? String ?? "",
                codec: s["codec_name"] as? String ?? "unknown",
                codecLong: s["codec_long_name"] as? String ?? "",
                width: int(s["width"]),
                height: int(s["height"]),
                fps: fps,
                channels: int(s["channels"]),
                channelLayout: s["channel_layout"] as? String,
                sampleRate: int(s["sample_rate"]),
                bitRate: int(s["bit_rate"]),
                language: tags["language"] as? String,
                title: tags["title"] as? String,
                isAttachedPic: (int(disp["attached_pic"]) ?? 0) == 1,
                rotation: rot
            )
        }

        return MediaInfo(
            duration: dbl(fmt["duration"]) ?? maxStreamDuration,
            formatName: fmt["format_name"] as? String ?? "",
            formatLong: fmt["format_long_name"] as? String ?? "",
            size: Int64(dbl(fmt["size"]) ?? 0),
            bitRate: int(fmt["bit_rate"]),
            streams: streams
        )
    }
}

enum ItemStatus: Equatable {
    case analyzing
    case ready
    case queued
    case converting
    case paused
    case done
    case failed(String)
    case cancelled
    case skipped(String)

    var isActive: Bool { self == .converting || self == .paused }
    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }
}

enum Prefs {
    static let outputMode = "outputMode"
    static let outputFolder = "outputFolder"
    static let suffix = "filenameSuffix"
    static let conflict = "conflictPolicy"
    static let maxConcurrent = "maxConcurrent"
    static let notify = "notifyWhenDone"
    static let sound = "playSound"
    static let reveal = "revealWhenDone"
    static let preventSleep = "preventSleep"
    static let settings = "conversionSettings"

    static var defaultOutputFolder: String {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Converted").path
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            outputMode: "source",
            outputFolder: defaultOutputFolder,
            suffix: "",
            conflict: "rename",
            maxConcurrent: 2,
            notify: true,
            sound: true,
            reveal: false,
            preventSleep: true,
        ])
    }
}

enum Fmt {
    static func duration(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "–" }
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func timestamp(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        let s = t - Double(h * 3600 + m * 60)
        let sec = s.truncatingRemainder(dividingBy: 1) < 0.001 ? String(format: "%02d", Int(s)) : String(format: "%04.1f", s)
        return h > 0 ? String(format: "%d:%02d:", h, m) + sec : String(format: "%d:", m) + sec
    }

    static func parseTime(_ str: String) -> Double? {
        let parts = str.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.3f", v)
    }

    static func fps(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.01 ? "\(Int(v.rounded()))" : String(format: "%.2f", v)
    }
}
