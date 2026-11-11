import ArgumentParser
import DogecoinKit
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Validate a header cache"
    )

    @Argument(help: "Path to headers.sqlite or the directory that holds it")
    var input: String

    func run() throws {
        let paths = try resolveHeaderCachePaths(inputPath: input)
        let metadata = try loadMetadata(from: paths.metadataURL)

        print("Verifying header cache...")
        print("  Expected: \(formatNumber(metadata.headerCount)) headers")

        let actualSize = try fileSize(at: paths.headersURL)
        if metadata.compressedSize != actualSize {
            throw RuntimeError("File size mismatch: metadata \(metadata.compressedSize) bytes, file \(actualSize) bytes")
        }
        print("  \u{2713} File size matches")

        print("  Checking SHA256 checksum...")
        let checksum = try sha256Hex(ofFile: paths.headersURL)
        if normalizedHex(checksum) != normalizedHex(metadata.checksumSHA256) {
            // Opening a cache for writing is enough to change it: SQLite
            // rewrites the file's header when it switches journal modes.
            throw RuntimeError("""
                Checksum mismatch: metadata \(metadata.checksumSHA256), computed \(checksum).
                The file is not the one that was exported. Export it again.
                """)
        }
        print("  \u{2713} Checksum matches")

        print("  Validating database contents...")
        // Read-only: opening the file for writing changes it, and the cache
        // that was just checked would no longer be the cache that ships.
        let db = try HeaderDatabase(readOnlyPath: paths.headersURL.path)

        guard let tip = try db.getTip() else {
            throw RuntimeError("Database has no tip header")
        }

        if Int(tip.height) != metadata.tipHeight {
            throw RuntimeError("Tip height mismatch: metadata \(metadata.tipHeight), database \(tip.height)")
        }
        print("  \u{2713} Tip height matches")

        // The metadata counts the best chain: genesis through the tip.
        if metadata.headerCount != metadata.tipHeight + 1 {
            throw RuntimeError("Header count mismatch: metadata says \(metadata.headerCount) headers for a tip at height \(metadata.tipHeight)")
        }
        // The database may hold more: headers of branches that lost out.
        let storedCount = try db.getHeaderCount()
        if storedCount < metadata.headerCount {
            throw RuntimeError("Header count mismatch: metadata \(metadata.headerCount), database \(storedCount)")
        }
        print("  \u{2713} Header count matches")
        if storedCount > metadata.headerCount {
            print("    (plus \(formatNumber(storedCount - metadata.headerCount)) headers off the best chain)")
        }

        let tipHashHex = tip.hash.map { String(format: "%02x", $0) }.joined()
        if normalizedHex(tipHashHex) != normalizedHex(metadata.tipHash) {
            throw RuntimeError("Tip hash mismatch: metadata \(metadata.tipHash), database \(tipHashHex)")
        }
        print("  \u{2713} Tip hash matches")

        // Validate chain linkage (sample check)
        print("  Validating chain linkage (sampling)...")
        try validateChainLinkage(db: db, headerCount: metadata.headerCount)
        print("  \u{2713} Chain linkage valid")

        print("")
        print("Verification complete!")
        print("  Headers: \(formatNumber(metadata.headerCount))")
        print("  Tip: \(metadata.tipHash.prefix(16))...")
    }

    private func validateChainLinkage(db: HeaderDatabase, headerCount: Int) throws {
        // Check genesis
        guard let genesis = try db.getHeader(height: 0) else {
            throw RuntimeError("Missing genesis header")
        }
        if genesis.prevBlockHash != Data(count: 32) {
            throw RuntimeError("Genesis has non-zero prev block")
        }

        // Sample heights to verify linkage
        let sampleHeights = [1, 10, 100, 1000, 10000, 100000, 500000, 1000000, headerCount - 1]
            .filter { $0 > 0 && $0 < headerCount }

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
}
