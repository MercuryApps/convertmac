import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageConverter {
    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func typeIdentifier(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return UTType.jpeg.identifier
        case "png": return UTType.png.identifier
        case "heic": return UTType.heic.identifier
        case "webp": return UTType.webP.identifier
        case "tiff", "tif": return UTType.tiff.identifier
        default: return UTType(filenameExtension: ext)?.identifier ?? UTType.jpeg.identifier
        }
    }

    static let writableTypes: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    static func canWrite(_ ext: String) -> Bool {
        writableTypes.contains(typeIdentifier(for: ext))
    }

    static func inspect(_ url: URL) -> (MediaInfo, NSImage?)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation >= 5 { swap(&w, &h) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let stream = StreamInfo(index: 0, type: "video", codec: url.pathExtension.lowercased(), codecLong: "Image",
                                width: w, height: h, fps: nil, channels: nil, channelLayout: nil, sampleRate: nil,
                                bitRate: nil, language: nil, title: nil, isAttachedPic: false, rotation: 0)
        let info = MediaInfo(duration: 0, formatName: url.pathExtension.lowercased(), formatLong: "Image",
                             size: size, bitRate: nil, streams: [stream])
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary)
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        return (info, thumb)
    }

    static func convert(source: URL, output: URL, ext: String, settings s: ConversionSettings,
                        crop: NormalizedRect?, applyGeometry: Bool) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ConversionError(message: "Couldn't read this image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ConversionError(message: "Couldn't decode this image")
        }

        if let crop, !crop.isFull {
            let rect = CGRect(x: Double(image.width) * crop.x, y: Double(image.height) * crop.y,
                              width: Double(image.width) * crop.width, height: Double(image.height) * crop.height).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }
        if applyGeometry, s.rotation != 0 || s.flipHorizontal || s.flipVertical {
            image = try transform(image, rotation: s.rotation, flipH: s.flipHorizontal, flipV: s.flipVertical)
        }
        if s.imageMaxSize > 0, max(image.width, image.height) > s.imageMaxSize {
            image = try resize(image, longestSide: s.imageMaxSize)
        }
        let type = typeIdentifier(for: ext)
        if type == UTType.jpeg.identifier, image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast {
            image = try flatten(image)
        }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw ConversionError(message: "This Mac can't write \(ext.uppercased()) images")
        }
        var outProps: [CFString: Any] = [:]
        if s.keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
                if let v = props[key] { outProps[key] = v }
            }
            if !s.stripLocation, let gps = props[kCGImagePropertyGPSDictionary] { outProps[kCGImagePropertyGPSDictionary] = gps }
            if var tiff = outProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                outProps[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        outProps[kCGImagePropertyOrientation] = 1
        if [UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier].contains(type) {
            outProps[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.1, s.imageQuality))
        }
        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError(message: "Couldn't save the \(ext.uppercased()) file")
        }
    }

    private static func context(width: Int, height: Int, opaque: Bool = false) throws -> CGContext {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
            throw ConversionError(message: "Not enough memory to process this image")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    private static func transform(_ image: CGImage, rotation: Int, flipH: Bool, flipV: Bool) throws -> CGImage {
        let w = image.width, h = image.height
        let swapped = rotation == 90 || rotation == 270
        let ctx = try context(width: swapped ? h : w, height: swapped ? w : h)
        let outW = CGFloat(ctx.width), outH = CGFloat(ctx.height)
        ctx.translateBy(x: outW / 2, y: outH / 2)
        ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let out = ctx.makeImage() else { throw ConversionError(message: "Couldn't rotate this image") }
        return out
    }

    private static func resize(_ image: CGImage, longestSide: Int) throws -> CGImage {
        let scale = Double(longestSide) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        let ctx = try context(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConversionError(message: "Couldn't resize this image") }
        return out
    }

    private static func flatten(_ image: CGImage) throws -> CGImage {
        let ctx = try context(width: image.width, height: image.height, opaque: true)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw ConversionError(message: "Couldn't process transparency") }
        return out
    }
}
