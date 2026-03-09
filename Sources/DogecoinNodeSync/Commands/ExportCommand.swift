import ArgumentParser
import DogecoinKit
import Foundation

/// Export format options
enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case sqlite
    case lzfse
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export headers to a bundle file (SQLite default, or LZFSE)"
    )

    @Option(name: .long, help: "Output directory for headers.sqlite + metadata.json")
    var output: String

    @Option(name: .long, help: "Network to export (mainnet or testnet)")
    var network: NetworkOption = .mainnet

    @Option(name: .long, help: "Optional path to an existing header cache")
    var storage: String?

    @Option(name: .long, help: "Export format: sqlite (default) or lzfse")
    var format: ExportFormat = .sqlite

    func run() async throws {
        switch format {
        case .sqlite:
            try exportSQLite()
        case .lzfse:
            try await exportLZFSE()
        }
    }

    private func exportSQLite() throws {
        let outputDirectory = try resolveOutputDirectory(output)
        let headersURL = outputDirectory.appendingPathComponent("headers.sqlite")
        let metadataURL = outputDirectory.appendingPathComponent("metadata.json")
        let storageURL = storage.map { URL(fileURLWithPath: $0, isDirectory: true) }

        // Get the source database path (matches DogecoinNodeSync storage location)
        let sourceDBPath: String
        if let storageDir = storageURL {
            sourceDBPath = storageDir.appendingPathComponent("headers.sqlite").path
        } else {
            // Default storage location: ~/Library/Caches/DogecoinKit/headers/<network>/
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let defaultStorage = caches.appendingPathComponent("DogecoinKit/headers/\(network.rawValue)")
            sourceDBPath = defaultStorage.appendingPathComponent("headers.sqlite").path
        }

        guard FileManager.default.fileExists(atPath: sourceDBPath) else {
            throw RuntimeError("Source database not found at \(sourceDBPath)")
        }

        // Remove existing output files
        try? FileManager.default.removeItem(at: headersURL)
        try? FileManager.default.removeItem(atPath: headersURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: headersURL.path + "-shm")

        // Get tip info and vacuum to output in one go
        let totalHeaders: Int
        let tipHeight: Int32
        let tipHashHex: String

        print("Reading source database...")
        let sourceDB = try HeaderDatabase(path: sourceDBPath)
        guard let tipRecord = try sourceDB.getTip() else {
            throw RuntimeError("Header chain has no tip")
        }

        if tipRecord.height < 0 {
            throw RuntimeError("Header chain is empty")
        }

        totalHeaders = Int(tipRecord.height + 1)
        tipHeight = tipRecord.height
        tipHashHex = tipRecord.hash.map { String(format: "%02x", $0) }.joined()

        print("Exporting \(formatNumber(totalHeaders)) headers to \(headersURL.lastPathComponent)")
        let startTime = Date()

        // Use VACUUM INTO to create a clean, standalone copy (must be outside transaction)
        print("Creating clean database copy...")
        try sourceDB.executeWithoutTransaction("VACUUM INTO '\(headersURL.path)'")

        // Compute checksum
        print("Computing checksum...")
        let checksum = try sha256Hex(ofFile: headersURL)
        let fileSizeValue = try fileSize(at: headersURL)

        let metadata = HeaderCacheMetadata(
            version: 2,  // Version 2 for SQLite format
            network: network.rawValue,
            headerCount: totalHeaders,
            tipHeight: Int(tipHeight),
            tipHash: tipHashHex,
            generatedAt: Date(),
            compressedSize: fileSizeValue,  // SQLite size (not compressed)
            uncompressedSize: fileSizeValue,
            checksumSHA256: checksum
        )

        try writeMetadata(metadata, to: metadataURL)

        let elapsed = Date().timeIntervalSince(startTime)
        print("")
        print("Export complete!")
        print("  Format: SQLite")
        print("  Headers: \(formatNumber(totalHeaders))")
        print("  Tip height: \(formatNumber(Int(tipHeight)))")
        print("  Database size: \(formatBytes(fileSizeValue))")
        print("  Time: \(String(format: "%.1f", elapsed))s")
        print("  Output: \(outputDirectory.path)")
    }

    private func exportLZFSE() async throws {
        let outputDirectory = try resolveOutputDirectory(output)
        let headersURL = outputDirectory.appendingPathComponent("headers.bin.lzfse")
        let metadataURL = outputDirectory.appendingPathComponent("metadata.json")
        let storageURL = storage.map { URL(fileURLWithPath: $0, isDirectory: true) }

        print("Loading header chain...")
        let chain = HeaderChain(network: network.value, storageDirectory: storageURL)
        guard let tip = await chain.tip else {
            throw RuntimeError("Header chain has no tip")
        }

        if tip.height < 0 {
            throw RuntimeError("Header chain is empty")
        }

        let totalHeaders = tip.height + 1
        print("Exporting \(formatNumber(Int(totalHeaders))) headers to \(headersURL.lastPathComponent)")

        let writer = try LZFSEStreamWriter(outputURL: headersURL)
        defer { writer.close() }

        var headerCount = 0
        var uncompressedSize = 0
        var lastHashHex = tip.header.hashHex
        let startTime = Date()
        var lastUpdateTime = startTime

        var height: Int32 = 0
        while height <= tip.height {
            guard let stored = await chain.getHeader(height: height) else {
                throw RuntimeError("Missing header at height \(height)")
            }
            let headerData = stored.header.serializeCore()
            try writer.write(headerData)
            headerCount += 1
            uncompressedSize += headerData.count
            lastHashHex = stored.header.hashHex
            height += 1

            // Update progress every 0.1 seconds
            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= 0.1 {
                lastUpdateTime = now
                let progress = Double(height) / Double(totalHeaders)
                printProgress(current: Int(height), total: Int(totalHeaders), percent: progress)
            }
        }

        // Final progress update
        printProgress(current: Int(totalHeaders), total: Int(totalHeaders), percent: 1.0)
        print("") // New line after progress bar

        print("Finalizing compression...")
        let checksum = try writer.finalize()

        let metadata = HeaderCacheMetadata(
            version: 1,
            network: network.rawValue,
            headerCount: headerCount,
            tipHeight: Int(tip.height),
            tipHash: lastHashHex,
            generatedAt: Date(),
            compressedSize: writer.compressedSize,
            uncompressedSize: uncompressedSize,
            checksumSHA256: checksum
        )

        try writeMetadata(metadata, to: metadataURL)

        let elapsed = Date().timeIntervalSince(startTime)
        let compressionRatio = Double(uncompressedSize) / Double(writer.compressedSize)
        print("")
        print("Export complete!")
        print("  Format: LZFSE")
        print("  Headers: \(formatNumber(headerCount))")
        print("  Tip height: \(formatNumber(Int(tip.height)))")
        print("  Uncompressed: \(formatBytes(uncompressedSize))")
        print("  Compressed: \(formatBytes(writer.compressedSize)) (\(String(format: "%.1fx", compressionRatio)) ratio)")
        print("  Time: \(String(format: "%.1f", elapsed))s")
        print("  Output: \(outputDirectory.path)")
    }
}
