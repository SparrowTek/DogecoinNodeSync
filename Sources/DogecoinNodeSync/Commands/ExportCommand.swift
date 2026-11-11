import ArgumentParser
import DogecoinKit
import Foundation

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export headers to a header cache: headers.sqlite and metadata.json"
    )

    @Option(name: .long, help: "Output directory for headers.sqlite + metadata.json")
    var output: String

    @Option(name: .long, help: "Network to export (mainnet or testnet)")
    var network: NetworkOption = .mainnet

    @Option(name: .long, help: "Optional path to an existing header cache")
    var storage: String?

    func run() throws {
        let outputDirectory = try resolveOutputDirectory(output)
        let headersURL = outputDirectory.appendingPathComponent("headers.sqlite")
        let metadataURL = outputDirectory.appendingPathComponent("metadata.json")

        // The database `sync` writes to
        let sourceDBPath = try headerStorageDirectory(custom: storage, network: network)
            .appendingPathComponent("headers.sqlite").path

        guard FileManager.default.fileExists(atPath: sourceDBPath) else {
            throw RuntimeError("Source database not found at \(sourceDBPath)")
        }

        // Remove existing output files
        try? FileManager.default.removeItem(at: headersURL)
        try? FileManager.default.removeItem(atPath: headersURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: headersURL.path + "-shm")

        print("Reading source database...")
        let sourceDB = try HeaderDatabase(path: sourceDBPath)
        guard let tip = try sourceDB.getTip(), tip.height >= 0 else {
            throw RuntimeError("Header chain is empty")
        }

        // Genesis is at height 0, so the best chain holds one header more
        // than its tip's height.
        let headerCount = Int(tip.height) + 1
        let tipHashHex = tip.hash.map { String(format: "%02x", $0) }.joined()

        print("Exporting \(formatNumber(headerCount)) headers to \(headersURL.lastPathComponent)")
        let startTime = Date()

        // Use VACUUM INTO to create a clean, standalone copy (must be outside transaction)
        print("Creating clean database copy...")
        let quotedPath = headersURL.path.replacingOccurrences(of: "'", with: "''")
        try sourceDB.executeWithoutTransaction("VACUUM INTO '\(quotedPath)'")

        // Compute checksum
        print("Computing checksum...")
        let checksum = try sha256Hex(ofFile: headersURL)
        let fileSizeValue = try fileSize(at: headersURL)

        let metadata = HeaderCacheMetadata(
            version: 2,
            network: network.rawValue,
            headerCount: headerCount,
            tipHeight: Int(tip.height),
            tipHash: tipHashHex,
            generatedAt: Date(),
            // The database is not compressed: both sizes are the file's.
            compressedSize: fileSizeValue,
            uncompressedSize: fileSizeValue,
            checksumSHA256: checksum
        )

        try writeMetadata(metadata, to: metadataURL)

        let elapsed = Date().timeIntervalSince(startTime)
        print("")
        print("Export complete!")
        print("  Headers: \(formatNumber(headerCount))")
        print("  Tip height: \(formatNumber(Int(tip.height)))")
        print("  Database size: \(formatBytes(fileSizeValue))")
        print("  Time: \(String(format: "%.1f", elapsed))s")
        print("  Output: \(outputDirectory.path)")
    }
}
