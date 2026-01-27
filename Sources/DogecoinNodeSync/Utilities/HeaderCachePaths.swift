import DogecoinKit
import Foundation

struct HeaderCachePaths {
    let headersURL: URL
    let metadataURL: URL
}

func resolveOutputDirectory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false

    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        if !isDirectory.boolValue {
            throw RuntimeError("Output path is not a directory: \(url.path)")
        }
    } else {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    return url
}

func resolveHeaderCachePaths(inputPath: String) throws -> HeaderCachePaths {
    let inputURL = URL(fileURLWithPath: inputPath)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false

    guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
        throw RuntimeError("Path not found: \(inputURL.path)")
    }

    let headersURL: URL
    let metadataURL: URL

    if isDirectory.boolValue {
        // Directory: look for headers.sqlite first, then headers.bin.lzfse
        let sqliteURL = inputURL.appendingPathComponent("headers.sqlite")
        let lzfseURL = inputURL.appendingPathComponent("headers.bin.lzfse")

        if fileManager.fileExists(atPath: sqliteURL.path) {
            headersURL = sqliteURL
        } else if fileManager.fileExists(atPath: lzfseURL.path) {
            headersURL = lzfseURL
        } else {
            throw RuntimeError("No headers file found in directory. Expected headers.sqlite or headers.bin.lzfse")
        }
        metadataURL = inputURL.appendingPathComponent("metadata.json")
    } else {
        // Direct file path
        headersURL = inputURL
        metadataURL = inputURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
    }

    guard fileManager.fileExists(atPath: headersURL.path) else {
        throw RuntimeError("Headers file not found: \(headersURL.path)")
    }

    guard fileManager.fileExists(atPath: metadataURL.path) else {
        throw RuntimeError("Metadata file not found: \(metadataURL.path)")
    }

    return HeaderCachePaths(headersURL: headersURL, metadataURL: metadataURL)
}

func loadMetadata(from url: URL) throws -> HeaderCacheMetadata {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(HeaderCacheMetadata.self, from: data)
    } catch {
        throw RuntimeError("Failed to decode metadata: \(error.localizedDescription)")
    }
}

func writeMetadata(_ metadata: HeaderCacheMetadata, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(metadata)
    try data.write(to: url, options: [.atomic])
}
