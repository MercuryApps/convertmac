import Foundation

struct JobInput {
    let url: URL
    let info: MediaInfo?
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var audioTrack = 0
    var crop: NormalizedRect? = nil
    var subtitleURL: URL? = nil
    var burnSubtitles = false
    var subtitleStream = 0
    var tags: MediaTags? = nil

    var start: Double { max(0, trimStart ?? 0) }

    var clipDuration: Double {
        guard let info else { return 0 }
        let end = min(trimEnd ?? info.duration, info.duration > 0 ? info.duration : .infinity)
        return max(0, end - start)
    }

    var hasVideo: Bool { info.map { !$0.videoStreams.isEmpty } ?? true }
    var hasAudio: Bool { info.map { !$0.audioStreams.isEmpty } ?? true }

    var selectedAudio: StreamInfo? {
        let streams = info?.audioStreams ?? []
        let idx = max(0, audioTrack)
        return idx < streams.count ? streams[idx] : streams.first
    }

    var croppedSize: (width: Int, height: Int)? {
        guard let d = info?.displaySize else { return nil }
        guard let c = crop, !c.isFull else { return d }
        return (max(2, Int(Double(d.width) * c.width) / 2 * 2), max(2, Int(Double(d.height) * c.height) / 2 * 2))
    }
}

enum CommandBuilder {
    private static let mpeg2Rates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    private static let toneMapChain = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    static func resolvedVideoCodec(_ s: ConversionSettings, _ f: OutputFormat) -> VideoCodec {
        f.videoCodecs.contains(s.videoCodec) ? s.videoCodec : f.defaultVideoCodec
    }

    static func resolvedAudioCodec(_ s: ConversionSettings, _ f: OutputFormat) -> AudioCodec {
        f.audioCodecs.contains(s.audioCodec) ? s.audioCodec : f.defaultAudioCodec
    }

    static func keepsHDR(_ input: JobInput, merging: Bool, _ s: ConversionSettings, _ f: OutputFormat) -> Bool {
        guard !merging, input.info?.isHDR == true, f.supportsHDR, s.hdrMode != .toneMap else { return false }
        return [.hevc, .av1, .vp9, .prores].contains(resolvedVideoCodec(s, f))
    }

    static func outputDuration(_ inputs: [JobInput], _ s: ConversionSettings) -> Double {
        inputs.map(\.clipDuration).reduce(0, +) / max(0.01, s.playbackSpeed)
    }

    static func arguments(inputs: [JobInput], output: URL, settings s: ConversionSettings,
                          format f: OutputFormat, encoders: Set<String>, workDir: URL) -> [String] {
        precondition(!inputs.isEmpty)
        var g = Graph(workDir: workDir)
        let merging = inputs.count > 1
        let speed = s.playbackSpeed > 0 ? s.playbackSpeed : 1
        let duration = outputDuration(inputs, s)

        let mediaIndex: [Int] = inputs.map { input in
            var opts: [String] = []
            if input.start > 0 { opts += ["-ss", Fmt.number(input.start)] }
            if let end = input.trimEnd, end > input.start { opts += ["-t", Fmt.number(end - input.start)] }
            return g.addInput(opts, input.url.path)
        }
        let primary = inputs[0]

        var out: [String] = []
        switch f.kind {
        case .image:
            return []

        case .audio:
            let acodec = resolvedAudioCodec(s, f)
            let audioLabel = audioGraph(inputs, mediaIndex, s, acodec, merging: merging, speed: speed, duration: duration, g: &g)
            out += ["-map", audioLabel]
            out += audioCodecArgs(acodec, s, primary, encoders, merging: merging)
            out += coverArtArgs(primary, s, f, g: &g)
            out += metadataArgs(primary, s)

        case .gif:
            let base = videoBase(inputs, mediaIndex, s, f, merging: merging, keepHDR: false, g: &g)
            var post = geometryFilters(s)
            if speed != 1 { post.append("setpts=PTS/\(Fmt.number(speed))") }
            post += fadeFilters(s, duration: duration, audio: false)
            post.append("fps=\(max(1, s.gifFPS))")
            if s.gifWidth > 0 { post.append("scale=\(s.gifWidth):-1:flags=lanczos") }
            var label = g.chain(base, post)
            label = watermark(label, s, outputWidth: s.gifWidth > 0 ? s.gifWidth : (primary.croppedSize?.width ?? 480), g: &g)
            let final = g.chain(label, ["split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"])
            out += ["-map", final, "-an", "-sn", "-dn", "-loop", "0"]
            out += ["-map_metadata", "-1"]

        case .video:
            let vcodec = resolvedVideoCodec(s, f)
            let acodec = resolvedAudioCodec(s, f)
            let keepHDR = keepsHDR(primary, merging: merging, s, f)
            let wantAudio = !s.removeAudio && inputs.contains(where: \.hasAudio)

            if !merging && vcodec == .copy {
                if let v = primary.info?.primaryVideo { out += ["-map", "\(mediaIndex[0]):\(v.index)"] } else { out += ["-map", "0:v:0?"] }
                out += ["-c:v", "copy"]
                if f.isMP4Family, primary.info?.primaryVideo?.codec == "hevc" { out += ["-tag:v", "hvc1"] }
            } else if inputs.contains(where: \.hasVideo) {
                let base = videoBase(inputs, mediaIndex, s, f, merging: merging, keepHDR: keepHDR, g: &g)
                let (label, codecArgs) = videoTail(base, inputs, s, f, vcodec, encoders, keepHDR: keepHDR,
                                                   merging: merging, speed: speed, duration: duration, g: &g)
                out += ["-map", label] + codecArgs
            }

            if wantAudio {
                if !merging && acodec == .copy {
                    if let a = primary.selectedAudio, primary.audioTrack >= 0 {
                        out += ["-map", "\(mediaIndex[0]):\(a.index)"]
                    } else {
                        out += ["-map", "0:a?"]
                    }
                    out += ["-c:a", "copy"]
                } else if !merging && primary.audioTrack < 0 && f.ext != "avi" {
                    for a in primary.info?.audioStreams ?? [] {
                        out += ["-map", "\(mediaIndex[0]):\(a.index)"]
                    }
                    out += audioCodecArgs(acodec, s, primary, encoders, merging: false)
                    let af = audioPostFilters(s, speed: speed, duration: duration)
                    if !af.isEmpty { out += ["-af", af.joined(separator: ",")] }
                } else {
                    let label = audioGraph(inputs, mediaIndex, s, acodec, merging: merging, speed: speed, duration: duration, g: &g)
                    out += ["-map", label] + audioCodecArgs(acodec, s, primary, encoders, merging: merging)
                }
            } else {
                out += ["-an"]
            }

            if !merging { out += subtitleArgs(primary, mediaIndex[0], s, f, g: &g) } else { out += ["-sn"] }
            out += ["-dn"]
            out += metadataArgs(primary, s)
        }

        var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        a += g.inputArgs
        if !g.filters.isEmpty { a += ["-filter_complex", g.filters.joined(separator: ";")] }
        a += out
        if f.isMP4Family { a += ["-movflags", "+faststart"] }
        if f.ext == "m4r" { a += ["-f", "ipod"] }
        a.append(output.path)
        return a
    }

    static func snapshotArguments(input: JobInput, at time: Double, output: URL, settings s: ConversionSettings) -> [String] {
        var vf: [String] = []
        if let c = cropFilter(input) { vf.append(c) }
        if input.info?.isHDR == true { vf.append(toneMapChain) }
        vf += geometryFilters(s)
        var a = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
        if let v = input.info?.primaryVideo {
            a += ["-ss", Fmt.number(max(0, time)), "-i", input.url.path, "-map", "0:\(v.index)"]
        } else if let art = input.info?.coverArt {
            a += ["-i", input.url.path, "-map", "0:\(art.index)"]
        } else {
            a += ["-i", input.url.path]
        }
        a += ["-frames:v", "1", "-update", "1"]
        if !vf.isEmpty { a += ["-vf", vf.joined(separator: ",")] }
        a += ["-c:v", "png", output.path]
        return a
    }

    struct Graph {
        let workDir: URL
        var inputArgs: [String] = []
        var filters: [String] = []
        var mergedAudio: String?
        private var inputCount = 0
        private var labelCount = 0

        init(workDir: URL) { self.workDir = workDir }

        mutating func addInput(_ options: [String], _ path: String) -> Int {
            inputArgs += options + ["-i", path]
            inputCount += 1
            return inputCount - 1
        }

        mutating func newLabel(_ prefix: String = "l") -> String {
            labelCount += 1
            return "[\(prefix)\(labelCount)]"
        }

        mutating func chain(_ input: String, _ steps: [String]) -> String {
            let label = newLabel()
            filters.append(input + (steps.isEmpty ? "null" : steps.joined(separator: ",")) + label)
            return label
        }

        mutating func audioChain(_ input: String, _ steps: [String]) -> String {
            let label = newLabel("a")
            filters.append(input + (steps.isEmpty ? "anull" : steps.joined(separator: ",")) + label)
            return label
        }

        func link(_ source: URL, as name: String) -> String {
            let dest = workDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.createSymbolicLink(at: dest, withDestinationURL: source)
            return dest.path
        }

        func write(_ text: String, as name: String) -> String {
            let dest = workDir.appendingPathComponent(name)
            try? text.write(to: dest, atomically: true, encoding: .utf8)
            return dest.path
        }
    }

    private static func cropFilter(_ input: JobInput) -> String? {
        guard let c = input.crop, !c.isFull, let d = input.info?.displaySize else { return nil }
        let w = max(2, Int(Double(d.width) * c.width) / 2 * 2)
        let h = max(2, Int(Double(d.height) * c.height) / 2 * 2)
        let x = min(d.width - w, max(0, Int(Double(d.width) * c.x)))
        let y = min(d.height - h, max(0, Int(Double(d.height) * c.y)))
        return "crop=\(w):\(h):\(x):\(y)"
    }

    private static func geometryFilters(_ s: ConversionSettings) -> [String] {
        var vf: [String] = []
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

    private static func subtitleBurnFilters(_ input: JobInput, _ inputIndex: Int, g: inout Graph) -> (filters: [String], overlayStream: String?) {
        guard input.burnSubtitles else { return ([], nil) }
        let shift = input.start > 0 ? Fmt.number(input.start) : nil
        func wrap(_ f: String) -> [String] {
            guard let shift else { return [f] }
            return ["setpts=PTS+\(shift)/TB", f, "setpts=PTS-STARTPTS"]
        }
        if let ext = input.subtitleURL {
            let path = g.link(ext, as: "subs-\(inputIndex).\(ext.pathExtension.lowercased())")
            return (wrap("subtitles=filename=\(path)"), nil)
        }
        let subs = input.info?.subtitleStreams ?? []
        guard !subs.isEmpty else { return ([], nil) }
        let idx = min(max(0, input.subtitleStream), subs.count - 1)
        if subs[idx].isTextSubtitle {
            let path = g.link(input.url, as: "media-\(inputIndex).\(input.url.pathExtension.lowercased())")
            return (wrap("subtitles=filename=\(path):si=\(idx)"), nil)
        }
        return ([], "[\(inputIndex):\(subs[idx].index)]")
    }

    private static func videoBase(_ inputs: [JobInput], _ idx: [Int], _ s: ConversionSettings, _ f: OutputFormat,
                                  merging: Bool, keepHDR: Bool, g: inout Graph) -> String {
        let common = mergeCanvas(inputs, s)
        var segments: [(v: String, a: String?)] = []

        for (i, input) in inputs.enumerated() {
            var label: String
            if input.hasVideo {
                let stream = input.info?.primaryVideo.map { "\(idx[i]):\($0.index)" } ?? "\(idx[i]):v:0"
                var pre: [String] = []
                if let c = cropFilter(input) { pre.append(c) }
                if input.info?.isHDR == true && !keepHDR { pre.append(toneMapChain) }
                if s.deinterlace { pre.append("yadif") }
                if s.denoiseVideo { pre.append("hqdn3d=3:3:6:6") }
                if s.stabilize { pre.append("deshake") }
                let burn = subtitleBurnFilters(input, idx[i], g: &g)
                pre += burn.filters
                label = g.chain("[\(stream)]", pre)
                if let overlay = burn.overlayStream {
                    let o = g.newLabel()
                    g.filters.append("\(label)\(overlay)overlay=eof_action=pass\(o)")
                    label = o
                }
            } else {
                label = g.newLabel("src")
                g.filters.append("color=c=black:s=\(common.width)x\(common.height):r=\(Fmt.number(common.fps)):d=\(Fmt.number(max(0.1, input.clipDuration)))\(label)")
            }

            if merging {
                label = g.chain(label, [
                    "scale=\(common.width):\(common.height):force_original_aspect_ratio=decrease",
                    "pad=\(common.width):\(common.height):(ow-iw)/2:(oh-ih)/2",
                    "setsar=1", "fps=\(Fmt.number(common.fps))", "format=yuv420p",
                ])
                let audio: String? = s.removeAudio || f.kind == .gif ? nil : mergeAudioSegment(input, idx[i], g: &g)
                segments.append((label, audio))
            } else {
                return label
            }
        }

        let withAudio = segments.allSatisfy { $0.a != nil } && !segments.isEmpty
        let joined = segments.map { $0.v + (withAudio ? ($0.a ?? "") : "") }.joined()
        let v = g.newLabel("v")
        if withAudio {
            let a = g.newLabel("a")
            g.filters.append("\(joined)concat=n=\(segments.count):v=1:a=1\(v)\(a)")
            g.mergedAudio = a
        } else {
            g.filters.append("\(joined)concat=n=\(segments.count):v=1:a=0\(v)")
        }
        return v
    }

    private static func mergeAudioSegment(_ input: JobInput, _ inputIndex: Int, g: inout Graph) -> String {
        if let a = input.selectedAudio {
            return g.audioChain("[\(inputIndex):\(a.index)]", ["aresample=48000", "aformat=sample_fmts=fltp:channel_layouts=stereo"])
        }
        let label = g.newLabel("a")
        g.filters.append("anullsrc=r=48000:cl=stereo:d=\(Fmt.number(max(0.1, input.clipDuration))),aformat=sample_fmts=fltp:channel_layouts=stereo\(label)")
        return label
    }

    static func mergeCanvas(_ inputs: [JobInput], _ s: ConversionSettings) -> (width: Int, height: Int, fps: Double) {
        let first = inputs.first(where: \.hasVideo)
        var size = first?.croppedSize ?? (1920, 1080)
        if inputs.count > 1, s.resolution > 0 {
            let landscape = size.width >= size.height
            let short = landscape ? size.height : size.width
            if short > s.resolution {
                let scale = Double(s.resolution) / Double(short)
                size = (Int(Double(size.width) * scale) / 2 * 2, Int(Double(size.height) * scale) / 2 * 2)
            }
        } else if inputs.count > 1, s.resolution == -1 {
            size = (max(2, s.customWidth / 2 * 2), max(2, s.customHeight / 2 * 2))
        }
        var fps = s.fps > 0 ? s.fps : (first?.info?.primaryVideo?.fps ?? 30)
        if fps <= 0 || fps > 120 { fps = 30 }
        return (max(2, size.width / 2 * 2), max(2, size.height / 2 * 2), (fps * 1000).rounded() / 1000)
    }

    static func outputWidth(_ inputs: [JobInput], _ s: ConversionSettings) -> Int {
        if inputs.count > 1 { return mergeCanvas(inputs, s).width }
        guard var d = inputs.first?.croppedSize else { return 1920 }
        if s.rotation == 90 || s.rotation == 270 { d = (d.height, d.width) }
        if s.resolution == -1 { return s.customWidth }
        if s.resolution > 0 {
            let landscape = d.width >= d.height
            if landscape, d.height > s.resolution { return d.width * s.resolution / d.height }
            if !landscape, d.width > s.resolution { return s.resolution }
        }
        return d.width
    }

    private static func fadeFilters(_ s: ConversionSettings, duration: Double, audio: Bool) -> [String] {
        var r: [String] = []
        let name = audio ? "afade" : "fade"
        if s.fadeIn > 0 { r.append("\(name)=t=in:st=0:d=\(Fmt.number(s.fadeIn))") }
        if s.fadeOut > 0, duration > s.fadeOut {
            r.append("\(name)=t=out:st=\(Fmt.number(duration - s.fadeOut)):d=\(Fmt.number(s.fadeOut))")
        }
        return r
    }

    private static func watermark(_ label: String, _ s: ConversionSettings, outputWidth: Int, g: inout Graph) -> String {
        guard s.watermarkEnabled else { return label }
        let opacity = Fmt.number(min(1, max(0.05, s.watermarkOpacity)))
        switch s.watermarkKind {
        case .text:
            let text = s.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let font = systemFont() else { return label }
            let textFile = g.write(text, as: "watermark.txt")
            let fontFile = g.link(font, as: "watermark-font.\(font.pathExtension)")
            let (x, y): (String, String)
            switch s.watermarkPosition {
            case .topLeft: (x, y) = ("h*0.03", "h*0.03")
            case .topRight: (x, y) = ("w-tw-h*0.03", "h*0.03")
            case .center: (x, y) = ("(w-tw)/2", "(h-th)/2")
            case .bottomLeft: (x, y) = ("h*0.03", "h-th-h*0.03")
            case .bottomRight: (x, y) = ("w-tw-h*0.03", "h-th-h*0.03")
            }
            let size = Fmt.number(max(1, s.watermarkSize) / 250)
            return g.chain(label, ["drawtext=fontfile=\(fontFile):textfile=\(textFile):expansion=none:fontsize=h*\(size):fontcolor=white@\(opacity):shadowcolor=black@0.5:shadowx=2:shadowy=2:x=\(x):y=\(y)"])
        case .image:
            let url = URL(fileURLWithPath: s.watermarkImagePath)
            guard !s.watermarkImagePath.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return label }
            let img = g.addInput(["-loop", "1"], url.path)
            let width = max(8, Int(Double(outputWidth) * s.watermarkSize / 100) / 2 * 2)
            let wm = g.chain("[\(img):v]", ["scale=\(width):-1", "format=rgba", "colorchannelmixer=aa=\(opacity)"])
            let (x, y): (String, String)
            switch s.watermarkPosition {
            case .topLeft: (x, y) = ("main_h*0.03", "main_h*0.03")
            case .topRight: (x, y) = ("main_w-overlay_w-main_h*0.03", "main_h*0.03")
            case .center: (x, y) = ("(main_w-overlay_w)/2", "(main_h-overlay_h)/2")
            case .bottomLeft: (x, y) = ("main_h*0.03", "main_h-overlay_h-main_h*0.03")
            case .bottomRight: (x, y) = ("main_w-overlay_w-main_h*0.03", "main_h-overlay_h-main_h*0.03")
            }
            let o = g.newLabel()
            g.filters.append("\(label)\(wm)overlay=x=\(x):y=\(y):shortest=1\(o)")
            return o
        }
    }

    static func systemFont() -> URL? {
        ["/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func videoTail(_ base: String, _ inputs: [JobInput], _ s: ConversionSettings, _ f: OutputFormat,
                                  _ c: VideoCodec, _ enc: Set<String>, keepHDR: Bool, merging: Bool,
                                  speed: Double, duration: Double, g: inout Graph) -> (String, [String]) {
        let primary = inputs[0]
        var vf = geometryFilters(s)

        if !merging {
            var dims = primary.croppedSize
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
        }
        if speed != 1 { vf.append("setpts=PTS/\(Fmt.number(speed))") }
        vf += fadeFilters(s, duration: duration, audio: false)

        var label = g.chain(base, vf)
        label = watermark(label, s, outputWidth: outputWidth(inputs, s), g: &g)

        let q = s.quality.rawValue
        let hw = c.hardwareEncoder.map { s.hardwareAcceleration && enc.contains($0) } ?? false
        let sp = s.speed.index
        var pix: String? = keepHDR ? "yuv420p10le" : "yuv420p"
        var r: [String] = []

        let kbps: Int = {
            if s.rateControl == .targetSize {
                return targetVideoBitrate(inputs, s, f, duration: duration)
            }
            return max(100, s.videoBitrate)
        }()
        let byBitrate = s.rateControl != .quality && c.supportsBitrate
        let sizeCapped = s.rateControl == .targetSize

        func bitrate(capped: Bool) -> [String] {
            if sizeCapped { return ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 5 / 4)k", "-bufsize", "\(kbps * 2)k"] }
            return capped ? ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"] : ["-b:v", "\(kbps)k"]
        }

        let trc = primary.info?.primaryVideo?.colorTransfer ?? "smpte2084"

        switch c {
        case .h264:
            if hw && !sizeCapped {
                r += ["-c:v", "h264_videotoolbox"]
                r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([75, 65, 55, 45, 35][q])"]
            } else {
                r += ["-c:v", "libx264", "-preset", ["veryfast", "medium", "slow"][sp]]
                r += byBitrate ? bitrate(capped: true) : ["-crf", "\([17, 20, 23, 26, 30][q])"]
            }
        case .hevc:
            if hw && !sizeCapped {
                r += ["-c:v", "hevc_videotoolbox"]
                r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([72, 62, 52, 44, 36][q])"]
                if keepHDR { r += ["-profile:v", "main10"]; pix = "p010le" }
            } else {
                var params = "log-level=error"
                if keepHDR { params += ":hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=\(trc):colormatrix=bt2020nc" }
                r += ["-c:v", "libx265", "-preset", ["veryfast", "medium", "slow"][sp], "-x265-params", params]
                r += byBitrate ? bitrate(capped: true) : ["-crf", "\([19, 23, 26, 29, 32][q])"]
            }
            if f.isMP4Family { r += ["-tag:v", "hvc1"] }
        case .av1:
            r += ["-c:v", "libsvtav1", "-preset", ["10", "8", "5"][sp]]
            r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-crf", "\([24, 30, 35, 40, 46][q])"]
        case .vp9:
            r += ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", ["5", "3", "1"][sp]]
            if sizeCapped {
                r += ["-b:v", "\(kbps * 9 / 10)k", "-maxrate", "\(kbps)k", "-bufsize", "\(kbps * 2)k"]
            } else {
                r += byBitrate ? ["-b:v", "\(kbps)k"] : ["-crf", "\([24, 31, 34, 38, 44][q])", "-b:v", "0"]
            }
            if keepHDR { r += ["-profile:v", "2"] }
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
            r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([2, 3, 5, 8, 12][q])"]
            if f.ext == "avi" { r += ["-vtag", "xvid"] }
        case .mpeg2:
            r += ["-c:v", "mpeg2video"]
            r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([2, 3, 5, 8, 12][q])"]
        case .wmv:
            r += ["-c:v", "wmv2"]
            r += byBitrate ? bitrate(capped: false) : ["-q:v", "\([2, 4, 6, 9, 13][q])"]
        case .gif, .copy:
            break
        }

        if keepHDR {
            r += ["-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc"]
        }
        if let pix { label = g.chain(label, ["format=\(pix)"]) }

        if !merging {
            if s.fps > 0 {
                r += ["-r", Fmt.number(s.fps)]
            } else if c == .mpeg2, let src = primary.info?.primaryVideo?.fps, !mpeg2Rates.contains(where: { abs($0 - src) < 0.01 }) {
                r += ["-r", "30"]
            }
        }
        return (label, r)
    }

    static func targetVideoBitrate(_ inputs: [JobInput], _ s: ConversionSettings, _ f: OutputFormat, duration: Double) -> Int {
        guard duration > 0 else { return max(100, s.videoBitrate) }
        let totalKbps = s.targetSizeMB * 8000 * 0.95 / duration
        var audioKbps = 0.0
        if !s.removeAudio && inputs.contains(where: \.hasAudio) {
            let ac = resolvedAudioCodec(s, f)
            if ac.usesBitrate {
                audioKbps = Double(s.audioBitrate)
            } else {
                let sr = Double(inputs[0].selectedAudio?.sampleRate ?? 48000)
                let ch = Double(inputs[0].selectedAudio?.channels ?? 2)
                audioKbps = ac.isLossless ? sr * ch * Double(s.bitDepth) / 1000 * (ac == .pcm || ac == .aiff ? 1 : 0.6) : 256
            }
        }
        return max(100, Int(totalKbps - audioKbps))
    }

    private static func atempoChain(_ speed: Double) -> [String] {
        var s = speed, out: [String] = []
        while s > 2 { out.append("atempo=2"); s /= 2 }
        while s < 0.5 { out.append("atempo=0.5"); s /= 0.5 }
        if abs(s - 1) > 0.0001 { out.append("atempo=\(Fmt.number(s))") }
        return out
    }

    private static func audioPostFilters(_ s: ConversionSettings, speed: Double, duration: Double) -> [String] {
        var af: [String] = []
        if s.denoiseAudio { af.append("afftdn=nf=-25") }
        if speed != 1 { af += atempoChain(speed) }
        if s.volumeDB != 0 { af.append("volume=\(Fmt.number(s.volumeDB))dB") }
        if s.normalize { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
        af += fadeFilters(s, duration: duration, audio: true)
        return af
    }

    private static func audioGraph(_ inputs: [JobInput], _ idx: [Int], _ s: ConversionSettings, _ c: AudioCodec,
                                   merging: Bool, speed: Double, duration: Double, g: inout Graph) -> String {
        var base: String
        if merging {
            if let merged = g.mergedAudio {
                base = merged
            } else {
                let segs = inputs.enumerated().map { i, input in mergeAudioSegment(input, idx[i], g: &g) }
                let a = g.newLabel("a")
                g.filters.append("\(segs.joined())concat=n=\(segs.count):v=0:a=1\(a)")
                base = a
            }
        } else if let a = inputs[0].selectedAudio {
            base = "[\(idx[0]):\(a.index)]"
        } else {
            base = "[\(idx[0]):a:0]"
        }
        return g.audioChain(base, audioPostFilters(s, speed: speed, duration: duration))
    }

    private static func audioCodecArgs(_ c: AudioCodec, _ s: ConversionSettings, _ input: JobInput,
                                       _ enc: Set<String>, merging: Bool) -> [String] {
        var r: [String] = []
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
        case .copy: return ["-c:a", "copy"]
        }

        let src = input.selectedAudio
        let srcRate = merging ? 48000 : src?.sampleRate
        let srcChannels = merging ? 2 : (src?.channels ?? 2)

        var ar = s.sampleRate
        if ar == 0 && s.normalize { ar = srcRate ?? 48000 }
        if ar != 0 && !c.sampleRateOptions.contains(ar) { ar = 48000 }
        if ar == 0, let rate = srcRate {
            if (c == .opus || c == .ac3) && !c.sampleRateOptions.contains(rate) { ar = 48000 }
            if let maxRate = c.maxSampleRate, rate > maxRate { ar = maxRate }
        }
        if ar > 0 { r += ["-ar", "\(ar)"] }

        if s.channels > 0 {
            r += ["-ac", "\(c.maxChannels.map { min($0, s.channels) } ?? s.channels)"]
        } else if let maxCh = c.maxChannels, srcChannels > maxCh || nativeVorbis {
            r += ["-ac", "\(maxCh)"]
        }
        return r
    }

    private static func subtitleArgs(_ input: JobInput, _ inputIndex: Int, _ s: ConversionSettings, _ f: OutputFormat, g: inout Graph) -> [String] {
        guard f.supportsSubtitles, !input.burnSubtitles else { return ["-sn"] }
        var maps: [String] = []
        let embedded = s.keepSubtitles ? (input.info?.subtitleStreams ?? []) : []
        if f.ext == "mkv" {
            maps += embedded.flatMap { ["-map", "\(inputIndex):\($0.index)"] }
        } else {
            maps += embedded.filter(\.isTextSubtitle).flatMap { ["-map", "\(inputIndex):\($0.index)"] }
        }
        if let ext = input.subtitleURL {
            let sub = g.addInput([], ext.path)
            maps += ["-map", "\(sub):0"]
        }
        guard !maps.isEmpty else { return ["-sn"] }
        let codec: String
        if f.ext == "mkv" {
            codec = input.subtitleURL == nil ? "copy" : (["ass", "ssa"].contains(input.subtitleURL!.pathExtension.lowercased()) ? "ass" : "srt")
        } else {
            codec = "mov_text"
        }
        if f.ext == "mkv" && input.subtitleURL != nil && !embedded.isEmpty {
            return maps + ["-c:s", "copy", "-c:s:\(embedded.count)", codec]
        }
        return maps + ["-c:s", codec]
    }

    private static func coverArtArgs(_ input: JobInput, _ s: ConversionSettings, _ f: OutputFormat, g: inout Graph) -> [String] {
        var r: [String] = ["-sn", "-dn"]
        guard f.supportsCoverArt, input.tags?.removeCover != true else { return r + ["-vn"] }
        if let cover = input.tags?.coverURL {
            let idx = g.addInput([], cover.path)
            r += ["-map", "\(idx):v:0"]
        } else if s.keepCoverArt, let art = input.info?.coverArt {
            r += ["-map", "0:\(art.index)"]
        } else {
            return r + ["-vn"]
        }
        r += ["-c:v", "mjpeg", "-q:v", "2", "-vf", "scale='min(1400,iw)':-2", "-disposition:v:0", "attached_pic"]
        if f.ext == "mp3" { r += ["-id3v2_version", "3"] }
        return r
    }

    private static func metadataArgs(_ input: JobInput, _ s: ConversionSettings) -> [String] {
        var r: [String] = s.keepMetadata ? ["-map_metadata", "0", "-map_chapters", "0"] : ["-map_metadata", "-1", "-map_chapters", "-1"]
        if let tags = input.tags {
            for (k, v) in tags.metadataPairs {
                let original = input.info?.tags[k] ?? (k == "date" ? input.info?.tags["year"] : nil) ?? ""
                if v != original || (!s.keepMetadata && !v.isEmpty) { r += ["-metadata", "\(k)=\(v)"] }
            }
        }
        return r
    }

    static func shellString(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map { arg in
            let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=+,@%".contains($0) }
            return safe ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
