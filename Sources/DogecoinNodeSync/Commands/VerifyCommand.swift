import ArgumentParser
import DogecoinKit
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Validate a header cache file (SQLite or LZFSE)"
    )

    @Argument(help: "Path to headers.sqlite, headers.bin.lzfse, or their directory")
    var input: String

    func run() throws {
        let paths = try resolveHeaderCachePaths(inputPath: input)
        let metadata = try loadMetadata(from: paths.metadataURL)

        // Detect format based on file extension or metadata version
        let isSQLite = paths.headersURL.pathExtension == "sqlite" || metadata.version >= 2

        if isSQLite {
            try verifySQLite(paths: paths, metadata: metadata)
        } else {
            try verifyLZFSE(paths: paths, metadata: metadata)
        }
    }

    private func verifySQLite(paths: HeaderCachePaths, metadata: HeaderCacheMetadata) throws {
        print("Verifying SQLite header cache...")
        print("  Expected: \(formatNumber(metadata.headerCount)) headers")

        let actualSize = try fileSize(at: paths.headersURL)
        if metadata.compressedSize != actualSize {
            throw RuntimeError("File size mismatch: metadata \(metadata.compressedSize) bytes, file \(actualSize) bytes")
        }
        print("  \u{2713} File size matches")

        print("  Checking SHA256 checksum...")
        let checksum = try sha256Hex(ofFile: paths.headersURL)
        if normalizedHex(checksum) != normalizedHex(metadata.checksumSHA256) {
            throw RuntimeError("Checksum mismatch: metadata \(metadata.checksumSHA256), computed \(checksum)")
        }
        print("  \u{2713} Checksum matches")

        print("  Validating database contents...")
        let db = try HeaderDatabase(path: paths.headersURL.path)
        let count = try db.getHeaderCount()

        if count != metadata.headerCount {
            throw RuntimeError("Header count mismatch: metadata \(metadata.headerCount), database \(count)")
        }
        print("  \u{2713} Header count matches")

        guard let tip = try db.getTip() else {
            throw RuntimeError("Database has no tip header")
        }

        if Int(tip.height) != metadata.tipHeight {
            throw RuntimeError("Tip height mismatch: metadata \(metadata.tipHeight), database \(tip.height)")
        }
        print("  \u{2713} Tip height matches")

        let tipHashHex = tip.hash.map { String(format: "%02x", $0) }.joined()
        if normalizedHex(tipHashHex) != normalizedHex(metadata.tipHash) {
            throw RuntimeError("Tip hash mismatch: metadata \(metadata.tipHash), database \(tipHashHex)")
        }
        print("  \u{2713} Tip hash matches")

        // Validate chain linkage (sample check)
        print("  Validating chain linkage (sampling)...")
        try validateChainLinkage(db: db, totalHeaders: metadata.headerCount)
        print("  \u{2713} Chain linkage valid")

        print("")
        print("Verification complete!")
        print("  Format: SQLite")
        print("  Headers: \(formatNumber(metadata.headerCount))")
        print("  Tip: \(metadata.tipHash.prefix(16))...")
    }

    private func validateChainLinkage(db: HeaderDatabase, totalHeaders: Int) throws {
        // Check genesis
        guard let genesis = try db.getHeader(height: 0) else {
            throw RuntimeError("Missing genesis header")
        }
        if genesis.prevBlockHash != Data(count: 32) {
            throw RuntimeError("Genesis has non-zero prev block")
        }

        // Sample random heights to verify linkage
        let sampleHeights = [1, 10, 100, 1000, 10000, 100000, 500000, 1000000, totalHeaders - 1]
            .filter { $0 > 0 && $0 < totalHeaders }

        for height in sampleHeights {
            guard let header = try db.getHeader(height: Int32(height)) else {
                throw RuntimeError("Missing header at height \(height)")
            }
            guard let prevHeader = try db.getHeader(height: Int32(height - 1)) else {
                throw RuntimeError("Missing header at height \(height - 1)")
            }
            if header.prevBlockHash != prevHeader.hash {
                throw RuntimeError("Chain linkage broken at height \(height)")
            }
        }
    }

    private func verifyLZFSE(paths: HeaderCachePaths, metadata: HeaderCacheMetadata) throws {
        let compressedSize = try fileSize(at: paths.headersURL)

        print("Verifying LZFSE header cache...")
        print("  Expected: \(formatNumber(metadata.headerCount)) headers")

        if metadata.compressedSize != compressedSize {
            throw RuntimeError("Compressed size mismatch: metadata \(metadata.compressedSize) bytes, file \(compressedSize) bytes")
        }
        print("  \u{2713} File size matches")

        print("  Checking SHA256 checksum...")
        let checksum = try sha256Hex(ofFile: paths.headersURL)
        if normalizedHex(checksum) != normalizedHex(metadata.checksumSHA256) {
            throw RuntimeError("Checksum mismatch: metadata \(metadata.checksumSHA256), computed \(checksum)")
        }
        print("  \u{2713} Checksum matches")

        print("  Decompressing and validating headers...")
        var validator = HeaderStreamValidator()
        var uncompressedSize = 0
        var lastUpdateTime = Date()
        let expectedUncompressed = metadata.uncompressedSize

        try decompressLZFSE(from: paths.headersURL) { chunk in
            uncompressedSize += chunk.count
            try validator.consume(chunk)

            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= 0.1 {
                lastUpdateTime = now
                let progress = Double(uncompressedSize) / Double(expectedUncompressed)
                printProgress(current: validator.headerCount, total: metadata.headerCount, percent: progress, indent: "  ")
            }
        }
        try validator.finalize()
        printProgress(current: metadata.headerCount, total: metadata.headerCount, percent: 1.0, indent: "  ")
        print("") // New line after progress

        if metadata.headerCount != validator.headerCount {
            throw RuntimeError("Header count mismatch: metadata \(metadata.headerCount), decoded \(validator.headerCount)")
        }
        print("  \u{2713} Header count matches")

        let expectedTipHeight = metadata.headerCount - 1
        if metadata.tipHeight != expectedTipHeight {
            throw RuntimeError("Tip height mismatch: metadata \(metadata.tipHeight), expected \(expectedTipHeight)")
        }

        if normalizedHex(metadata.tipHash) != normalizedHex(validator.tipHashHex) {
            throw RuntimeError("Tip hash mismatch: metadata \(metadata.tipHash), decoded \(validator.tipHashHex)")
        }
        print("  \u{2713} Tip hash matches")

        if metadata.uncompressedSize != uncompressedSize {
            throw RuntimeError("Uncompressed size mismatch: metadata \(metadata.uncompressedSize) bytes, decoded \(uncompressedSize) bytes")
        }

        print("")
        print("Verification complete!")
        print("  Format: LZFSE")
        print("  Headers: \(formatNumber(metadata.headerCount))")
        print("  Tip: \(metadata.tipHash.prefix(16))...")
    }
}
