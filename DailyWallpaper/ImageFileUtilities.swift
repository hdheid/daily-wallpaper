import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFileError: LocalizedError {
    case emptyFile
    case unsupportedImage
    case invalidDimensions
    case animatedOrMultipage

    var errorDescription: String? {
        switch self {
        case .emptyFile: "图片文件为空"
        case .unsupportedImage: "不支持或无法识别的图片格式"
        case .invalidDimensions: "图片尺寸无效"
        case .animatedOrMultipage: "不支持动画或多页图片"
        }
    }
}

enum ImageFileUtilities {
    static let hashChunkSize = 1_024 * 1_024

    static func inspect(url: URL, requireSingleFrame: Bool = true) throws -> ImageInspection {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true, (resourceValues.fileSize ?? 0) > 0 else {
            throw ImageFileError.emptyFile
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageFileError.unsupportedImage
        }

        let frameCount = CGImageSourceGetCount(source)
        if requireSingleFrame, frameCount != 1 {
            throw ImageFileError.animatedOrMultipage
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = integer(properties[kCGImagePropertyPixelWidth]),
            let height = integer(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            throw ImageFileError.invalidDimensions
        }

        guard
            let typeIdentifier = CGImageSourceGetType(source) as String?,
            let type = UTType(typeIdentifier),
            Self.isSupportedStaticImage(type)
        else {
            throw ImageFileError.unsupportedImage
        }

        let exifDate = extractEXIFDate(properties)
        return ImageInspection(
            pixelWidth: width,
            pixelHeight: height,
            frameCount: frameCount,
            uniformTypeIdentifier: typeIdentifier,
            mimeType: type.preferredMIMEType ?? "image/unknown",
            preferredFileExtension: normalizedExtension(for: type),
            exifDate: exifDate
        )
    }

    static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: hashChunkSize), !data.isEmpty else { break }
            // 每轮只保留 1 MB Data，哈希过程的内存不会随原图大小增长。
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isSupportedStaticImage(_ type: UTType) -> Bool {
        let supportedIdentifiers: Set<String> = [
            UTType.jpeg.identifier,
            UTType.png.identifier,
            UTType.heic.identifier,
            UTType.heif.identifier,
            UTType.tiff.identifier,
            UTType.webP.identifier
        ]
        return supportedIdentifiers.contains(type.identifier)
    }

    static func sanitizedPathComponent(_ input: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = String(String.UnicodeScalarView(input.unicodeScalars.filter { allowed.contains($0) }))
        return value.isEmpty ? fallback : String(value.prefix(64))
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func normalizedExtension(for type: UTType) -> String {
        if type.identifier == UTType.jpeg.identifier { return "jpg" }
        if type.identifier == UTType.tiff.identifier { return "tiff" }
        return type.preferredFilenameExtension ?? "image"
    }

    private static func extractEXIFDate(_ properties: [CFString: Any]) -> Date? {
        guard
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let rawValue = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: rawValue)
    }
}
