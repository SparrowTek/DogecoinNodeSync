import ArgumentParser
import DogecoinKit
import Foundation

/// Actor for thread-safe progress tracking
private actor ProgressTracker {
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

@main
struct DogecoinNodeSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sync Dogecoin block headers using SPV",
        discussion: """
            Downloads and validates Dogecoin block headers from the peer-to-peer network.
            Headers are stored locally and can be exported using HeaderCacheTools.

            Example:
              DogecoinNodeSync --network mainnet
              DogecoinNodeSync --network testnet --storage /path/to/headers
            """
    )

    @Option(name: .long, help: "Network to sync (mainnet or testnet)")
    var network: String = "mainnet"

    @Option(name: .long, help: "Custom storage directory for headers")
    var storage: String?

    func run() async throws {
        let dogecoinNetwork = try parseNetwork(network)
        let storageURL = storage.map { URL(fileURLWithPath: $0, isDirectory: true) }

        let networkName = dogecoinNetwork == .mainnet ? "mainnet" : "testnet"
        print("Starting header sync for \(networkName)...")
        if let path = storageURL?.path {
            print("Storage: \(path)")
        } else {
            print("Storage: ~/Library/Caches/DogecoinKit/headers/\(networkName)")
        }

        // Prevent system sleep during sync
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Syncing Dogecoin block headers"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let syncManager = SPVSyncManager(
            network: dogecoinNetwork,
            storageDirectory: storageURL
        )

        // Create async stream for events
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        let delegate = SyncDelegate(continuation: continuation)
        syncManager.delegate = delegate

        // Handle Ctrl+C gracefully - must retain the source to keep it alive
        let signalSource = setupSignalHandler(syncManager: syncManager, continuation: continuation)
        defer { withExtendedLifetime(signalSource) {} }

        // Start sync
        syncManager.start()

        let progressIndicator = ProgressIndicator()
        progressIndicator.startSpinner(message: "Connecting to peers")

        // Configuration
        let maxConsecutiveErrors = 10
        let noProgressTimeout: TimeInterval = 300

        // Process events with error tracking and progress timeout
        var hasReceivedFirstProgress = false
        var consecutiveErrors = 0
        let progressTracker = ProgressTracker()
        await progressTracker.initialize(height: syncManager.currentHeight)

        // Start a background task to check for progress timeout
        let timeoutTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // Check every 30 seconds

                let timeSinceProgress = await progressTracker.timeSinceLastProgress()
                if timeSinceProgress > noProgressTimeout {
                    continuation.yield(.timeout)
                    break
                }
            }
        }

        defer { timeoutTask.cancel() }

        for await event in stream {
            switch event {
            case .progress(let progress, let height):
                let target = syncManager.targetHeight

                // Reset error count and update progress time on successful progress
                let didProgress = await progressTracker.recordProgress(height: height)
                if didProgress {
                    consecutiveErrors = 0
                }

                if !hasReceivedFirstProgress {
                    hasReceivedFirstProgress = true
                    progressIndicator.stopSpinner()
                    print("") // New line after spinner
                }

                progressIndicator.updateProgress(
                    current: Int(height),
                    total: Int(target),
                    percent: progress
                )

            case .completed:
                progressIndicator.stopSpinner()
                let finalHeight = syncManager.currentHeight
                print("") // New line after progress bar
                print("")
                print("Sync complete!")
                print("Final height: \(finalHeight)")
                print("")
                print("Next step: Export headers using HeaderCacheTools")
                print("  cd Tools/HeaderCacheTools")
                print("  swift run HeaderCacheTools export --network \(networkName) --output <path>")
                return

            case .error(let error):
                consecutiveErrors += 1
                progressIndicator.stopSpinner()
                print("")
                print("Error (\(consecutiveErrors)/\(maxConsecutiveErrors)): \(error.localizedDescription)")

                if consecutiveErrors >= maxConsecutiveErrors {
                    print("")
                    print("Too many consecutive errors. Stopping sync.")
                    print("Current height: \(syncManager.currentHeight)")
                    print("Progress has been saved. Run again to resume.")
                    syncManager.stop()
                    return
                }

                // Restart spinner if we're still going
                if hasReceivedFirstProgress {
                    progressIndicator.startSpinner(message: "Recovering from error")
                }

            case .timeout:
                progressIndicator.stopSpinner()
                print("")
                print("")
                print("Sync stalled - no progress for \(Int(noProgressTimeout)) seconds")
                print("Current height: \(syncManager.currentHeight)")
                print("Progress has been saved. Run again to resume.")
                syncManager.stop()
                return

            case .interrupted:
                progressIndicator.stopSpinner()
                let currentHeight = syncManager.currentHeight
                print("")
                print("")
                print("Sync interrupted at height \(currentHeight)")
                print("Progress has been saved. Run again to resume.")
                return
            }
        }
    }

    private func parseNetwork(_ value: String) throws -> DogecoinNetwork {
        switch value.lowercased() {
        case "mainnet":
            return .mainnet
        case "testnet":
            return .testnet
        default:
            throw ValidationError("Unknown network: \(value). Use 'mainnet' or 'testnet'.")
        }
    }

    private func setupSignalHandler(
        syncManager: SPVSyncManager,
        continuation: AsyncStream<SyncEvent>.Continuation
    ) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        source.setEventHandler {
            continuation.yield(.interrupted)
            syncManager.stop()
            continuation.finish()
        }
        source.resume()
        return source
    }
}

// MARK: - Sync Events

enum SyncEvent: Sendable {
    case progress(Double, height: Int32)
    case completed
    case error(Error)
    case timeout
    case interrupted
}

// MARK: - Sync Delegate

final class SyncDelegate: SPVSyncDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<SyncEvent>.Continuation

    init(continuation: AsyncStream<SyncEvent>.Continuation) {
        self.continuation = continuation
    }

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) {
        continuation.yield(.progress(progress, height: height))
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) {
        continuation.yield(.completed)
        continuation.finish()
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) {
        // Headers are logged via progress updates
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) {
        continuation.yield(.error(error))
    }
}

// MARK: - Progress Indicator

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

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
