import CryptoKit
import Foundation

func formatNumber(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    } else if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    } else {
        return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}

func fileSize(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let sizeNumber = attributes[.size] as? NSNumber else {
        throw RuntimeError("Unable to read file size: \(url.path)")
    }
    return sizeNumber.intValue
}

func sha256Hex(ofFile url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 64 * 1024) ?? Data()
        if data.isEmpty {
            break
        }
        hasher.update(data: data)
    }

    return hexString(hasher.finalize())
}

func hexString(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

func normalizedHex(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
