import AppKit
import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var queue: QueueManager
    @EnvironmentObject private var toolkit: FFmpegToolkit
    @State private var category: FormatCategory = .video
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var renaming: UserPreset?
    @State private var renameText = ""

    private var format: OutputFormat { queue.format }
    private var s: ConversionSettings { queue.settings }
    private var vcodec: VideoCodec { CommandBuilder.resolvedVideoCodec(s, format) }
    private var acodec: AudioCodec { CommandBuilder.resolvedAudioCodec(s, format) }
    private var videoCopy: Bool { format.kind == .video && vcodec == .copy }
    private var audioCopy: Bool { acodec == .copy }
    private var usesHardware: Bool {
        guard let hw = vcodec.hardwareEncoder else { return false }
        return s.hardwareAcceleration && toolkit.has(hw) && s.rateControl != .targetSize
    }

    var body: some View {
        Form {
            formatSection
            switch format.kind {
            case .image:
                imageSection
                imageEditSection
            case .video:
                videoSection
                audioSection
                editSection
                effectsSection
                watermarkSection
                extrasSection
            case .gif:
                gifSection
                editSection
                effectsSection
                watermarkSection
                extrasSection
            case .audio:
                audioSection
                editSection
                effectsSection
                extrasSection
            }
            Section {
                HStack {
                    Button("Save as Preset…") {
                        presetName = ""
                        showSavePreset = true
                    }
                    Spacer()
                    Button("Reset to Defaults") { queue.select(format: format) }
                }
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
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                queue.savePreset(named: presetName)
                category = .saved
            }
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current format and every setting so you can reuse them with one click.")
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let p = renaming { queue.rename(preset: p, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var formatSection: some View {
        Section {
            Picker("Category", selection: $category) {
                ForEach(FormatCategory.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if category == .saved {
                savedPresets
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(OutputFormat.all.filter { $0.category == category }) { f in
                        FormatTile(name: f.name, detail: f.detail, symbol: f.symbol,
                                   selected: f.id == format.id && queue.activePresetID == nil,
                                   available: isAvailable(f)) {
                            queue.select(format: f)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Convert to")
        } footer: {
            Text("\(format.name): \(format.detail) · saves as .\(format.ext)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var savedPresets: some View {
        if queue.presets.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "star")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No saved presets yet")
                    .font(.callout.weight(.medium))
                Text("Set up a format the way you like it, then click Save as Preset at the bottom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(queue.presets) { p in
                    let f = OutputFormat.with(id: p.settings.formatID)
                    FormatTile(name: p.name, detail: "\(f.name) · .\(f.ext)", symbol: "star.fill",
                               selected: queue.activePresetID == p.id, available: true) {
                        queue.apply(preset: p)
                    }
                    .contextMenu {
                        Button("Update with Current Settings") { queue.savePreset(named: p.name) }
                        Button("Rename…") {
                            renameText = p.name
                            renaming = p
                        }
                        Divider()
                        Button("Delete", role: .destructive) { queue.delete(preset: p) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func isAvailable(_ f: OutputFormat) -> Bool {
        if f.kind == .image {
            return ImageConverter.canWrite(f.ext) || toolkit.has("libwebp")
        }
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
            if let hw = vcodec.hardwareEncoder, toolkit.has(hw), s.rateControl != .targetSize {
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
                        ForEach(RateControl.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                switch (vcodec.supportsBitrate ? s.rateControl : .quality) {
                case .bitrate:
                    LabeledContent("Bitrate") {
                        HStack(spacing: 4) {
                            TextField("kbps", value: $queue.settings.videoBitrate, format: .number.grouping(.never))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .labelsHidden()
                            Text("kbps").foregroundStyle(.secondary)
                        }
                    }
                case .targetSize:
                    LabeledContent("Target size") {
                        HStack(spacing: 4) {
                            TextField("MB", value: $queue.settings.targetSizeMB, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                                .labelsHidden()
                            Text("MB").foregroundStyle(.secondary)
                            Menu {
                                ForEach([("Discord (free)", 10.0), ("WhatsApp", 16.0), ("Email", 25.0), ("Discord Nitro", 50.0), ("100 MB", 100.0)], id: \.0) { item in
                                    Button("\(item.0) · \(Fmt.number(item.1)) MB") { queue.settings.targetSizeMB = item.1 }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    Text("Each file is squeezed to fit, with a little headroom. Very long videos at small sizes will look soft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .quality:
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
                Picker(selection: $queue.settings.hdrMode) {
                    ForEach(HDRMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("HDR videos")
                    Text(hdrHint)
                }
            }
            .disabled(videoCopy)
        }
    }

    private var hdrHint: String {
        let canKeep = [.hevc, .av1, .vp9, .prores].contains(vcodec) && format.supportsHDR
        switch s.hdrMode {
        case .toneMap: return "HDR footage is converted to normal colors for any screen"
        case .automatic: return canKeep ? "HDR is kept with \(vcodec.label)" : "Converted to normal colors so it doesn't look washed out"
        case .keep: return canKeep ? "Kept as 10-bit HDR" : "\(vcodec.label) can't store HDR, so it's converted"
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

    private var imageSection: some View {
        Section("Image") {
            if ["jpg", "heic", "webp"].contains(format.ext) {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $queue.settings.imageQuality, in: 0.3...1, step: 0.05)
                        Text("\(Int(s.imageQuality * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Picker("Size", selection: $queue.settings.imageMaxSize) {
                Text("Original").tag(0)
                Divider()
                ForEach([4096, 3000, 2048, 1600, 1080, 800, 512], id: \.self) { Text("Longest side \($0) px").tag($0) }
            }
            Toggle("Keep photo details (EXIF)", isOn: $queue.settings.keepMetadata)
            Toggle("Remove location", isOn: $queue.settings.stripLocation)
                .disabled(!s.keepMetadata)
            Text("Videos added here export a still frame from the trim start point.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageEditSection: some View {
        Section("Edit") {
            rotatePicker
            Toggle("Flip horizontally", isOn: $queue.settings.flipHorizontal)
            Toggle("Flip vertically", isOn: $queue.settings.flipVertical)
        }
    }

    private var rotatePicker: some View {
        Picker("Rotate", selection: $queue.settings.rotation) {
            Text("None").tag(0)
            Text("90° clockwise").tag(90)
            Text("180°").tag(180)
            Text("90° counter-clockwise").tag(270)
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

    private var hasVideo: Bool { format.kind == .video || format.kind == .gif }
    private var hasAudio: Bool { format.kind == .audio || (format.kind == .video && !s.removeAudio) }

    private var editSection: some View {
        Section("Edit") {
            Picker("Playback speed", selection: $queue.settings.playbackSpeed) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { v in
                    Text(v == 1 ? "Normal" : "\(Fmt.number(v))×").tag(v)
                }
            }
            .disabled(videoCopy || (format.kind == .audio && audioCopy))

            if hasVideo {
                Group {
                    rotatePicker
                    Toggle("Flip horizontally", isOn: $queue.settings.flipHorizontal)
                    Toggle("Flip vertically", isOn: $queue.settings.flipVertical)
                    if format.kind == .video {
                        Toggle(isOn: $queue.settings.deinterlace) {
                            Text("Deinterlace")
                            Text("Removes comb lines from old TV and camcorder footage")
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

    private var effectsSection: some View {
        Section("Effects") {
            let fades = [0.0, 0.5, 1, 2, 3, 5]
            Picker("Fade in", selection: $queue.settings.fadeIn) {
                ForEach(fades, id: \.self) { Text($0 == 0 ? "Off" : "\(Fmt.number($0)) s").tag($0) }
            }
            Picker("Fade out", selection: $queue.settings.fadeOut) {
                ForEach(fades, id: \.self) { Text($0 == 0 ? "Off" : "\(Fmt.number($0)) s").tag($0) }
            }
            if hasVideo {
                Toggle(isOn: $queue.settings.denoiseVideo) {
                    Text("Reduce video noise")
                    Text("Cleans up grain in dark or low-light footage")
                }
                Toggle(isOn: $queue.settings.stabilize) {
                    Text("Stabilize")
                    Text("Smooths out small camera shakes")
                }
            }
            if hasAudio {
                Toggle(isOn: $queue.settings.denoiseAudio) {
                    Text("Reduce background noise")
                    Text("Removes hiss and hum from recordings")
                }
            }
        }
        .disabled(videoCopy || (format.kind == .audio && audioCopy))
    }

    private var watermarkSection: some View {
        Section("Watermark") {
            Toggle("Add watermark", isOn: $queue.settings.watermarkEnabled)
            if s.watermarkEnabled {
                Picker("Type", selection: $queue.settings.watermarkKind) {
                    Text("Text").tag(WatermarkKind.text)
                    Text("Image").tag(WatermarkKind.image)
                }
                .pickerStyle(.segmented)
                if s.watermarkKind == .text {
                    TextField("Text", text: $queue.settings.watermarkText, prompt: Text("© Your Name"))
                } else {
                    LabeledContent("Image") {
                        HStack {
                            Text(s.watermarkImagePath.isEmpty ? "None" : URL(fileURLWithPath: s.watermarkImagePath).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseWatermarkImage() }
                        }
                    }
                }
                Picker("Position", selection: $queue.settings.watermarkPosition) {
                    ForEach(WatermarkPosition.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Size") {
                    Slider(value: $queue.settings.watermarkSize, in: 5...40, step: 1)
                }
                LabeledContent("Opacity") {
                    Slider(value: $queue.settings.watermarkOpacity, in: 0.1...1, step: 0.05)
                }
            }
        }
        .disabled(videoCopy)
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Choose a logo or image. PNGs with transparency work best."
        if panel.runModal() == .OK, let url = panel.url {
            queue.settings.watermarkImagePath = url.path
        }
    }

    private var extrasSection: some View {
        Section {
            if format.kind == .video && format.supportsSubtitles {
                Toggle(isOn: $queue.settings.keepSubtitles) {
                    Text("Keep subtitles")
                    Text(format.ext == "mkv" ? "All subtitle tracks are copied" : "Text subtitles (SRT, ASS…) are kept")
                }
            }
            if format.kind != .gif {
                Toggle("Keep metadata & chapters", isOn: $queue.settings.keepMetadata)
            }
            if format.supportsCoverArt {
                Toggle("Keep album artwork", isOn: $queue.settings.keepCoverArt)
            }
            Toggle(isOn: $queue.settings.mergeFiles) {
                Text("Merge all files into one")
                Text("Joins the list top to bottom. Drag files to change the order.")
            }
        } header: {
            Text("Extras")
        }
    }
}

struct FormatTile: View {
    let name: String
    let detail: String
    let symbol: String
    let selected: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
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
        .disabled(!available)
        .help(available ? "\(name) — \(detail)" : "\(name) isn't available with this FFmpeg build")
    }
}
