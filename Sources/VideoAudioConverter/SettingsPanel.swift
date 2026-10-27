import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var toolkit: FFmpegToolkit
    @State private var category: FormatCategory = .video

    private var format: OutputFormat { queue.format }
    private var s: ConversionSettings { queue.settings }
    private var vcodec: VideoCodec { CommandBuilder.resolvedVideoCodec(s, format) }
    private var acodec: AudioCodec { CommandBuilder.resolvedAudioCodec(s, format) }
    private var videoCopy: Bool { format.kind == .video && vcodec == .copy }
    private var audioCopy: Bool { acodec == .copy }
    private var usesHardware: Bool {
        guard let hw = vcodec.hardwareEncoder else { return false }
        return s.hardwareAcceleration && toolkit.has(hw)
    }

    var body: some View {
        Form {
            formatSection
            if format.kind == .video { videoSection }
            if format.kind == .gif { gifSection }
            if format.kind != .gif { audioSection }
            adjustSection
            if format.kind != .gif { extrasSection }
            Section {
                Button("Reset \(format.name) to Defaults") { queue.select(format: format) }
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .onAppear { category = format.category }
        .onChange(of: queue.settings.videoCodec) { _, new in
            if new == .prores && queue.settings.quality == .high { queue.settings.quality = .best }
        }
        .onChange(of: queue.settings.audioCodec) { _, new in
            if !new.bitrateOptions.contains(queue.settings.audioBitrate) {
                queue.settings.audioBitrate = new.defaultBitrate
            }
            if !new.sampleRateOptions.contains(queue.settings.sampleRate) {
                queue.settings.sampleRate = 0
            }
        }
    }

    private var formatSection: some View {
        Section {
            Picker("Category", selection: $category) {
                ForEach(FormatCategory.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(OutputFormat.all.filter { $0.category == category }) { f in
                    FormatTile(format: f, selected: f.id == format.id, available: isAvailable(f)) {
                        queue.select(format: f)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Convert to")
        } footer: {
            Text("\(format.name): \(format.detail) · saves as .\(format.ext)")
                .foregroundStyle(.secondary)
        }
    }

    private func isAvailable(_ f: OutputFormat) -> Bool {
        guard toolkit.checked, toolkit.isAvailable else { return true }
        if let v = f.videoCodecs.first, v != .copy, v != .gif, !toolkit.has(v.softwareEncoder) && !(v.hardwareEncoder.map(toolkit.has) ?? false) {
            return false
        }
        return true
    }

    private var videoSection: some View {
        Section("Video") {
            Picker("Codec", selection: $queue.settings.videoCodec) {
                ForEach(format.videoCodecs) { c in
                    Text(c.label).tag(c)
                }
            }
            if let hw = vcodec.hardwareEncoder, toolkit.has(hw) {
                Toggle(isOn: $queue.settings.hardwareAcceleration) {
                    Text("Hardware acceleration")
                    Text("Much faster using Apple's media engine")
                }
            }
            Group {
                Picker("Resolution", selection: $queue.settings.resolution) {
                    Text("Original").tag(0)
                    Divider()
                    Text("4K · 2160p").tag(2160)
                    Text("1440p").tag(1440)
                    Text("1080p Full HD").tag(1080)
                    Text("720p HD").tag(720)
                    Text("480p").tag(480)
                    Text("360p").tag(360)
                    Text("240p").tag(240)
                    Divider()
                    Text("Custom…").tag(-1)
                }
                if s.resolution == -1 {
                    LabeledContent("Size") {
                        HStack(spacing: 4) {
                            TextField("W", value: $queue.settings.customWidth, format: .number.grouping(.never))
                                .frame(width: 64)
                            Text("×")
                            TextField("H", value: $queue.settings.customHeight, format: .number.grouping(.never))
                                .frame(width: 64)
                        }
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                    }
                }
                Picker("Frame rate", selection: $queue.settings.fps) {
                    Text("Original").tag(0.0)
                    Divider()
                    ForEach([23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 120], id: \.self) { f in
                        Text("\(Fmt.fps(f)) fps").tag(f)
                    }
                }
                if vcodec.supportsBitrate {
                    Picker("Size control", selection: $queue.settings.rateControl) {
                        Text("Quality").tag(RateControl.quality)
                        Text("Bitrate").tag(RateControl.bitrate)
                    }
                    .pickerStyle(.segmented)
                }
                if s.rateControl == .bitrate && vcodec.supportsBitrate {
                    LabeledContent("Bitrate") {
                        HStack(spacing: 4) {
                            TextField("kbps", value: $queue.settings.videoBitrate, format: .number.grouping(.never))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .labelsHidden()
                            Text("kbps").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Picker(vcodec == .prores ? "Profile" : "Quality", selection: $queue.settings.quality) {
                        if vcodec == .prores {
                            Text("422 HQ").tag(QualityLevel.best)
                            Text("422").tag(QualityLevel.medium)
                            Text("422 LT").tag(QualityLevel.low)
                            Text("Proxy").tag(QualityLevel.smallest)
                        } else {
                            ForEach(QualityLevel.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                if vcodec.hasSpeedPreset && !usesHardware {
                    Picker("Encoder speed", selection: $queue.settings.speed) {
                        ForEach(EncoderSpeed.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .disabled(videoCopy)
        }
    }

    private var gifSection: some View {
        Section("GIF") {
            Picker("Frame rate", selection: $queue.settings.gifFPS) {
                ForEach([5, 10, 12, 15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Width", selection: $queue.settings.gifWidth) {
                ForEach([240, 320, 480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) }
                Text("Original").tag(0)
            }
            Text("Tip: trim clips to a few seconds — GIFs get big fast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            if format.kind == .video {
                Toggle("Remove audio", isOn: $queue.settings.removeAudio)
            }
            if !(format.kind == .video && s.removeAudio) {
                if format.audioCodecs.count > 1 {
                    Picker("Codec", selection: $queue.settings.audioCodec) {
                        ForEach(format.audioCodecs) { Text($0.label).tag($0) }
                    }
                } else {
                    LabeledContent("Codec", value: acodec.label)
                }
                Group {
                    if acodec.usesBitrate {
                        Picker("Bitrate", selection: $queue.settings.audioBitrate) {
                            ForEach(acodec.bitrateOptions, id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                    }
                    Picker("Sample rate", selection: $queue.settings.sampleRate) {
                        ForEach(acodec.sampleRateOptions, id: \.self) { r in
                            Text(r == 0 ? "Original" : String(format: "%g kHz", Double(r) / 1000)).tag(r)
                        }
                    }
                    Picker("Channels", selection: $queue.settings.channels) {
                        Text("Original").tag(0)
                        Text("Mono").tag(1)
                        Text("Stereo").tag(2)
                        if acodec.maxChannels == nil { Text("5.1 Surround").tag(6) }
                    }
                    if acodec.supportsBitDepth {
                        Picker("Bit depth", selection: $queue.settings.bitDepth) {
                            Text("16-bit").tag(16)
                            Text("24-bit").tag(24)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .disabled(audioCopy)
            }
        }
    }

    private var adjustSection: some View {
        Section("Edit") {
            let hasVideo = format.kind != .audio
            let hasAudio = format.kind != .gif && !(format.kind == .video && s.removeAudio)
            Picker("Playback speed", selection: $queue.settings.playbackSpeed) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { v in
                    Text(v == 1 ? "Normal" : "\(Fmt.number(v))×").tag(v)
                }
            }
            .disabled(videoCopy || (format.kind == .audio && audioCopy))

            if hasVideo {
                Group {
                    Picker("Rotate", selection: $queue.settings.rotation) {
                        Text("None").tag(0)
                        Text("90° clockwise").tag(90)
                        Text("180°").tag(180)
                        Text("90° counter-clockwise").tag(270)
                    }
                    Toggle("Flip horizontally", isOn: $queue.settings.flipHorizontal)
                    Toggle("Flip vertically", isOn: $queue.settings.flipVertical)
                    if format.kind == .video {
                        Toggle(isOn: $queue.settings.deinterlace) {
                            Text("Deinterlace")
                            Text("Removes comb lines from old TV / camcorder footage")
                        }
                    }
                }
                .disabled(videoCopy)
            }

            if hasAudio {
                Group {
                    LabeledContent("Volume") {
                        HStack {
                            Slider(value: $queue.settings.volumeDB, in: -20...20, step: 1)
                                .frame(minWidth: 100)
                            Text(s.volumeDB == 0 ? "0 dB" : String(format: "%+.0f dB", s.volumeDB))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Toggle(isOn: $queue.settings.normalize) {
                        Text("Normalize loudness")
                        Text("Evens out quiet and loud files (EBU R128)")
                    }
                }
                .disabled(audioCopy)
            }
        }
    }

    private var extrasSection: some View {
        Section("Extras") {
            if format.kind == .video && format.supportsSubtitles {
                Toggle(isOn: $queue.settings.keepSubtitles) {
                    Text("Keep subtitles")
                    Text(format.ext == "mkv" ? "All subtitle tracks are copied" : "Text subtitles (SRT, ASS…) are kept")
                }
            }
            Toggle("Keep metadata & chapters", isOn: $queue.settings.keepMetadata)
        }
    }
}

struct FormatTile: View {
    let format: OutputFormat
    let selected: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: format.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(format.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(format.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 22, alignment: .top)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.4)
        .help(available ? "\(format.name) — \(format.detail)" : "Your FFmpeg build lacks the encoder for \(format.name)")
    }
}
