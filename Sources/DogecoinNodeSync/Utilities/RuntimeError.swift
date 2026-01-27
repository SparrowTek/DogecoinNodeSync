import Foundation

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) {
        self.description = message
    }
}
