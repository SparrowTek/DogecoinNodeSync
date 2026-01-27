import ArgumentParser
import DogecoinKit
import Foundation

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print basic info about a header cache file"
    )

    @Argument(help: "Path to headers.sqlite, headers.bin.lzfse, or their directory")
    var input: String

    func run() throws {
        let paths = try resolveHeaderCachePaths(inputPath: input)
        let metadata = try loadMetadata(from: paths.metadataURL)
        let actualSize = try fileSize(at: paths.headersURL)
        let formatter = ISO8601DateFormatter()

        let isSQLite = paths.headersURL.pathExtension == "sqlite" || metadata.version >= 2
        let formatName = isSQLite ? "SQLite" : "LZFSE"

        print("Header cache:")
        print("  Format: \(formatName)")
        print("  Version: \(metadata.version)")
        print("  Network: \(metadata.network)")
        print("  Headers: \(metadata.headerCount)")
        print("  Tip: \(metadata.tipHeight) \(metadata.tipHash)")
        print("  Generated: \(formatter.string(from: metadata.generatedAt))")
        if isSQLite {
            print("  Database size: \(actualSize) bytes")
        } else {
            print("  Compressed size: \(actualSize) bytes (metadata \(metadata.compressedSize))")
            print("  Uncompressed size: \(metadata.uncompressedSize) bytes")
            if metadata.compressedSize > 0 {
                let ratio = Double(metadata.uncompressedSize) / Double(metadata.compressedSize)
                print("  Compression ratio: \(String(format: "%.1fx", ratio))")
            }
        }
        print("  Checksum SHA256: \(metadata.checksumSHA256)")
    }
}
