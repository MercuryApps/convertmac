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

    static func thumbnail(_ url: URL, ffmpeg: URL, at time: Double, width: Int = 240) async -> NSImage? {
        let r = await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", Fmt.number(max(0, time)), "-i", url.path,
            "-frames:v", "1", "-vf", "scale=\(width):-2", "-f", "image2pipe", "-c:v", "mjpeg", "-",
        ])
        guard r.status == 0, !r.stdout.isEmpty else { return nil }
        return NSImage(data: r.stdout)
    }

    static func detectBlackBars(_ url: URL, ffmpeg: URL, duration: Double, size: (width: Int, height: Int)) async -> NormalizedRect? {
        let start = duration > 20 ? duration * 0.3 : 0
        let r = await ProcessRunner.run(ffmpeg, [
            "-hide_banner", "-nostdin", "-ss", Fmt.number(start), "-i", url.path, "-t", "10",
            "-vf", "cropdetect=limit=24:round=2:reset=0", "-an", "-sn", "-f", "null", "-",
        ])
        let text = String(decoding: r.stderr, as: UTF8.self)
        guard let range = text.range(of: "crop=", options: .backwards) else { return nil }
        let parts = text[range.upperBound...].prefix { !$0.isWhitespace }.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 4, size.width > 0, size.height > 0, parts[0] > 0, parts[1] > 0 else { return nil }
        let w = Double(size.width), h = Double(size.height)
        return NormalizedRect(x: parts[2] / w, y: parts[3] / h, width: parts[0] / w, height: parts[1] / h)
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
