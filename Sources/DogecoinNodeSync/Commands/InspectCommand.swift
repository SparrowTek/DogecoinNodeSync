import ArgumentParser
import DogecoinKit
import Foundation

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Print basic info about a header cache"
    )

    @Argument(help: "Path to headers.sqlite or the directory that holds it")
    var input: String

    func run() throws {
        let paths = try resolveHeaderCachePaths(inputPath: input)
        let metadata = try loadMetadata(from: paths.metadataURL)
        let actualSize = try fileSize(at: paths.headersURL)
        let formatter = ISO8601DateFormatter()

        print("Header cache:")
        print("  Version: \(metadata.version)")
        print("  Network: \(metadata.network)")
        print("  Headers: \(metadata.headerCount)")
        print("  Tip: \(metadata.tipHeight) \(metadata.tipHash)")
        print("  Generated: \(formatter.string(from: metadata.generatedAt))")
        print("  Database size: \(actualSize) bytes")
        print("  Checksum SHA256: \(metadata.checksumSHA256)")
    }
}
