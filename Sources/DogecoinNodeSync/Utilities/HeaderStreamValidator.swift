import DogecoinKit
import Foundation

struct HeaderStreamValidator {
    private(set) var headerCount = 0
    private(set) var tipHashHex = ""
    private var lastHash: Data?
    private var leftover = Data()

    mutating func consume(_ data: Data) throws {
        let combined: Data
        if leftover.isEmpty {
            combined = data
        } else {
            var merged = Data()
            merged.reserveCapacity(leftover.count + data.count)
            merged.append(leftover)
            merged.append(data)
            combined = merged
        }
        var offset = 0

        while combined.count - offset >= BlockHeader.size {
            let range = offset..<(offset + BlockHeader.size)
            let headerData = combined.subdata(in: range)
            guard let header = BlockHeader.parse(from: headerData) else {
                throw RuntimeError("Failed to parse header at height \(headerCount)")
            }

            if headerCount == 0 {
                if header.prevBlock != Data(count: 32) {
                    throw RuntimeError("First header does not look like genesis")
                }
            } else if let previousHash = lastHash, header.prevBlock != previousHash {
                throw RuntimeError("Header chain mismatch at height \(headerCount)")
            }

            lastHash = header.hash
            tipHashHex = header.hashHex
            headerCount += 1
            offset += BlockHeader.size
        }

        if offset < combined.count {
            leftover = combined.subdata(in: offset..<combined.count)
        } else {
            leftover.removeAll(keepingCapacity: true)
        }
    }

    mutating func finalize() throws {
        if !leftover.isEmpty {
            throw RuntimeError("Trailing bytes found after decoding headers")
        }
        if headerCount == 0 {
            throw RuntimeError("No headers decoded")
        }
    }
}
