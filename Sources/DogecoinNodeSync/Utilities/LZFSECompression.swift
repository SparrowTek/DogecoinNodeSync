import Compression
import CryptoKit
import Foundation

final class LZFSEStreamWriter {
    private let fileHandle: FileHandle
    private let outputURL: URL
    private var stream: compression_stream
    private var outputBuffer: [UInt8]
    private var inputBuffer: [UInt8]
    private var inputBufferUsed: Int = 0
    private var hasher = SHA256()
    private(set) var compressedSize = 0
    private let chunkSize = 256 * 1024  // 256KB chunks for better compression

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputURL)

        self.outputBuffer = [UInt8](repeating: 0, count: chunkSize + 1024)
        self.inputBuffer = [UInt8](repeating: 0, count: chunkSize)

        // Initialize compression stream
        self.stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )

        let status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw RuntimeError("Failed to initialize LZFSE compressor")
        }
    }

    func write(_ data: Data) throws {
        // Add data to input buffer
        for byte in data {
            inputBuffer[inputBufferUsed] = byte
            inputBufferUsed += 1

            // When buffer is full, compress it
            if inputBufferUsed >= chunkSize {
                try flushInputBuffer(finalize: false)
            }
        }
    }

    private func flushInputBuffer(finalize: Bool) throws {
        guard inputBufferUsed > 0 || finalize else { return }

        let flags: Int32 = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

        try inputBuffer.withUnsafeBufferPointer { srcBuffer in
            stream.src_ptr = srcBuffer.baseAddress!
            stream.src_size = inputBufferUsed

            repeat {
                try outputBuffer.withUnsafeMutableBufferPointer { dstBuffer in
                    stream.dst_ptr = dstBuffer.baseAddress!
                    stream.dst_size = dstBuffer.count

                    let status = compression_stream_process(&stream, flags)

                    if status == COMPRESSION_STATUS_ERROR {
                        throw RuntimeError("LZFSE compression error")
                    }

                    let produced = dstBuffer.count - stream.dst_size
                    if produced > 0 {
                        let chunk = Data(dstBuffer.prefix(produced))
                        try fileHandle.write(contentsOf: chunk)
                        hasher.update(data: chunk)
                        compressedSize += produced
                    }

                    if status == COMPRESSION_STATUS_END {
                        return
                    }
                }
            } while stream.src_size > 0 || (finalize && stream.dst_size == 0)
        }

        inputBufferUsed = 0
    }

    func finalize() throws -> String {
        // Flush any remaining input
        try flushInputBuffer(finalize: true)

        try fileHandle.synchronize()
        try fileHandle.close()

        let digest = hasher.finalize()
        return hexString(digest)
    }

    func close() {
        compression_stream_destroy(&stream)
        try? fileHandle.close()
    }
}

func decompressLZFSE(from url: URL, chunkHandler: (Data) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
        dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
        src_size: 0,
        state: nil
    )
    let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
    guard initStatus != COMPRESSION_STATUS_ERROR else {
        throw RuntimeError("Failed to initialize LZFSE decompressor")
    }
    defer { compression_stream_destroy(&stream) }

    var outputBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    var inputBuffer = [UInt8]()
    var didFinish = false

    while !didFinish {
        // Read more input if needed
        if stream.src_size == 0 {
            let inputData = try handle.read(upToCount: 64 * 1024) ?? Data()
            inputBuffer = [UInt8](inputData)
        }

        let isFinal = inputBuffer.isEmpty && stream.src_size == 0
        let flags: Int32 = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

        try inputBuffer.withUnsafeBufferPointer { srcPtr in
            if stream.src_size == 0 && !inputBuffer.isEmpty {
                stream.src_ptr = srcPtr.baseAddress!
                stream.src_size = srcPtr.count
            }

            // Keep processing until we need more input or we're done
            while true {
                let (status, produced) = outputBuffer.withUnsafeMutableBufferPointer { outPtr -> (compression_status, Int) in
                    stream.dst_ptr = outPtr.baseAddress!
                    stream.dst_size = outPtr.count
                    let s = compression_stream_process(&stream, flags)
                    return (s, outPtr.count - stream.dst_size)
                }

                if status == COMPRESSION_STATUS_ERROR {
                    throw RuntimeError("LZFSE decompression failed")
                }

                if produced > 0 {
                    try chunkHandler(Data(outputBuffer.prefix(produced)))
                }

                if status == COMPRESSION_STATUS_END {
                    didFinish = true
                    break
                }

                // If no output produced and no input remaining, need more input
                if produced == 0 && stream.src_size == 0 {
                    break
                }
            }
        }

        // Clear input buffer after processing
        if stream.src_size == 0 {
            inputBuffer.removeAll()
        }

        // If we sent FINALIZE but didn't get END, that's an error
        if isFinal && !didFinish {
            throw RuntimeError("Unexpected end of compressed stream")
        }
    }
}
