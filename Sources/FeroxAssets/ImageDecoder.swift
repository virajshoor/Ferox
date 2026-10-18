import FeroxCore
import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// Image decoding.
///
/// On Apple platforms this uses ImageIO (PNG, JPEG, HEIC, TIFF, BMP, GIF, TGA, OpenEXR and
/// Radiance HDR as supported by the OS). LDR images decode to premultiplied RGBA8 (sRGB);
/// HDR formats decode to RGBA32 float. A built-in decoder for binary PPM/PFM is included on
/// every platform for tests and tooling.
public enum ImageDecoder {
    public static func decode(_ data: Data, _ name: String) throws -> ImageData {
        try decode(data, name, limits: .default)
    }

    public static func decode(_ data: Data, _ name: String, limits: DecodeLimits) throws -> ImageData {
        guard !data.isEmpty else { throw AssetError.corrupt(name, reason: "empty image data") }
        guard data.count <= limits.maxFileBytes else { throw AssetError.limitExceeded(name, reason: "image file too large") }
        if data.starts(with: Array("P6".utf8)) || data.starts(with: Array("PF".utf8)) {
            return try decodeNetpbm(data, name, limits: limits)
        }
        #if canImport(ImageIO) && canImport(CoreGraphics)
        return try decodeImageIO(data, name, limits: limits)
        #else
        throw AssetError.unsupportedFormat("\(name) (image decoding requires ImageIO on this platform)")
        #endif
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    static func decodeImageIO(_ data: Data, _ name: String, limits: DecodeLimits) throws -> ImageData {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(src) > 0,
            let image = CGImageSourceCreateImageAtIndex(src, 0, options)
        else { throw AssetError.corrupt(name, reason: "ImageIO could not decode the image") }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= limits.maxTextureDimension, h <= limits.maxTextureDimension else {
            throw AssetError.limitExceeded(name, reason: "dimensions \(w)×\(h) exceed \(limits.maxTextureDimension)")
        }
        let isHDR = image.bitsPerComponent > 8 && (image.bitmapInfo.contains(.floatComponents) || image.bitsPerComponent >= 16)
        if isHDR {
            let bytesPerRow = w * 16
            var buffer = Data(count: bytesPerRow * h)
            let ok: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                    let ctx = CGContext(
                        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: bytesPerRow, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw AssetError.corrupt(name, reason: "could not create a float bitmap context") }
            return ImageData(width: w, height: h, format: .rgba32Float, pixels: buffer)
        }
        let bytesPerRow = w * 4
        var buffer = Data(count: bytesPerRow * h)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw AssetError.corrupt(name, reason: "could not create a bitmap context") }
        return ImageData(width: w, height: h, format: .rgba8UnormSRGB, pixels: buffer)
    }
    #endif

    /// Binary PPM (`P6`, 8-bit) and PFM (`PF`, float RGB) decoder.
    static func decodeNetpbm(_ data: Data, _ name: String, limits: DecodeLimits) throws -> ImageData {
        let bytes = [UInt8](data)
        var pos = 0
        func token() throws -> String {
            while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 { pos += 1 }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "#") {
                while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
                return try token()
            }
            let start = pos
            while pos < bytes.count, !(bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09) { pos += 1 }
            guard pos > start else { throw AssetError.corrupt(name, reason: "truncated header") }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }
        let magic = try token()
        guard let w = Int(try token()), let h = Int(try token()), w > 0, h > 0, w <= limits.maxTextureDimension,
            h <= limits.maxTextureDimension
        else { throw AssetError.corrupt(name, reason: "invalid dimensions") }
        let maxTok = try token()
        pos += 1  // single whitespace before the raster
        if magic == "P6" {
            guard Int(maxTok) == 255 else { throw AssetError.unsupportedFormat("\(name) (only 8-bit PPM)") }
            guard bytes.count - pos >= w * h * 3 else { throw AssetError.corrupt(name, reason: "raster truncated") }
            var out = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                out[i * 4] = bytes[pos + i * 3]
                out[i * 4 + 1] = bytes[pos + i * 3 + 1]
                out[i * 4 + 2] = bytes[pos + i * 3 + 2]
            }
            return ImageData(width: w, height: h, format: .rgba8UnormSRGB, pixels: Data(out))
        }
        guard let scale = Float(maxTok) else { throw AssetError.corrupt(name, reason: "invalid PFM scale") }
        guard bytes.count - pos >= w * h * 12 else { throw AssetError.corrupt(name, reason: "raster truncated") }
        let little = scale < 0
        var out = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let o = pos + ((y * w + x) * 3 + c) * 4
                    var bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
                    if !little { bits = bits.byteSwapped }
                    // PFM stores rows bottom-to-top.
                    out[((h - 1 - y) * w + x) * 4 + c] = Float(bitPattern: bits)
                }
            }
        }
        return ImageData(width: w, height: h, format: .rgba32Float, pixels: out.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
