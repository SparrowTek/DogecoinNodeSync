import Foundation

/// Actor for thread-safe progress tracking
actor ProgressTracker {
    private var lastProgressTime = Date()
    private var lastHeight: Int32 = 0

    func initialize(height: Int32) {
        lastHeight = height
        lastProgressTime = Date()
    }

    func recordProgress(height: Int32) -> Bool {
        if height > lastHeight {
            lastHeight = height
            lastProgressTime = Date()
            return true
        }
        return false
    }

    func timeSinceLastProgress() -> TimeInterval {
        Date().timeIntervalSince(lastProgressTime)
    }
}

final class ProgressIndicator: @unchecked Sendable {
    private let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerIndex = 0
    private var spinnerTimer: DispatchSourceTimer?
    private var spinnerMessage = ""
    private let lock = NSLock()

    private let barWidth = 30
    private var lastUpdateTime: Date = .distantPast
    private let minUpdateInterval: TimeInterval = 0.1

    func startSpinner(message: String) {
        lock.lock()
        spinnerMessage = message
        spinnerIndex = 0
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            self?.renderSpinner()
        }

        lock.lock()
        spinnerTimer = timer
        lock.unlock()

        timer.resume()
    }

    func stopSpinner() {
        lock.lock()
        spinnerTimer?.cancel()
        spinnerTimer = nil
        lock.unlock()

        // Clear the spinner line
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
    }

    private func renderSpinner() {
        lock.lock()
        let frame = spinnerFrames[spinnerIndex]
        let message = spinnerMessage
        spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
        lock.unlock()

        print("\r\u{1B}[K\(frame) \(message)...", terminator: "")
        fflush(stdout)
    }

    func updateProgress(current: Int, total: Int, percent: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= minUpdateInterval else {
            return
        }
        lastUpdateTime = now

        let filledWidth = Int(percent * Double(barWidth))
        let emptyWidth = barWidth - filledWidth

        let filled = String(repeating: "█", count: filledWidth)
        let empty = String(repeating: "░", count: emptyWidth)
        let percentStr = String(format: "%5.1f%%", percent * 100)

        let currentStr = formatNumber(current)
        let totalStr = formatNumber(total)

        print("\r\u{1B}[K[\(filled)\(empty)] \(percentStr)  \(currentStr) / \(totalStr) headers", terminator: "")
        fflush(stdout)
    }
}

/// Prints a progress bar to the terminal (for export/verify operations)
func printProgress(current: Int, total: Int, percent: Double, indent: String = "") {
    let barWidth = 30
    let filledWidth = Int(percent * Double(barWidth))
    let emptyWidth = barWidth - filledWidth
    let filled = String(repeating: "█", count: filledWidth)
    let empty = String(repeating: "░", count: emptyWidth)
    let percentStr = String(format: "%5.1f%%", percent * 100)
    print("\r\(indent)[\(filled)\(empty)] \(percentStr)  \(formatNumber(current)) / \(formatNumber(total))", terminator: "")
    fflush(stdout)
}
