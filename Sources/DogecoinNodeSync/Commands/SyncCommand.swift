import ArgumentParser
import DogecoinKit
import Foundation

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync Dogecoin block headers using SPV",
        discussion: """
            Downloads and validates Dogecoin block headers from the peer-to-peer network.
            Headers are stored locally and can be exported using the export command.

            Example:
              DogecoinNodeSync sync --network mainnet
              DogecoinNodeSync sync --network testnet --storage /path/to/headers
            """
    )

    @Option(name: .long, help: "Network to sync (mainnet or testnet)")
    var network: String = "mainnet"

    @Option(name: [.short, .long], help: "Custom storage directory for headers")
    var storage: String?

    func run() async throws {
        let dogecoinNetwork = try parseNetwork(network)
        let storageURL = storage.map { URL(fileURLWithPath: $0, isDirectory: true) }

        let networkName = dogecoinNetwork == .mainnet ? "mainnet" : "testnet"
        print("Starting header sync for \(networkName)...")

        // Determine actual storage path for display
        let displayPath: String
        if let path = storageURL?.path {
            displayPath = path
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            displayPath = caches.appendingPathComponent("DogecoinKit/headers/\(networkName)").path
        }
        print("Storage: \(displayPath)")

        let syncManager = SPVSyncManager(
            network: dogecoinNetwork,
            storageDirectory: storageURL
        )

        let startingHeight = await syncManager.currentHeight
        if startingHeight > 0 {
            print("Resuming from height: \(startingHeight)")
        } else {
            print("Starting fresh sync from genesis")
        }

        // Prevent system sleep during sync
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Syncing Dogecoin block headers"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Create async stream for events
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        let delegate = SyncDelegate(continuation: continuation)
        await syncManager.setDelegate(delegate)

        // Handle Ctrl+C gracefully - must retain the source to keep it alive
        let signalSource = setupSignalHandler(syncManager: syncManager, continuation: continuation)
        defer { withExtendedLifetime(signalSource) {} }

        // Start sync
        await syncManager.start()

        let progressIndicator = ProgressIndicator()
        progressIndicator.startSpinner(message: "Connecting to peers")

        // Configuration
        let maxConsecutiveErrors = 10
        let noProgressTimeout: TimeInterval = 300

        // Process events with error tracking and progress timeout
        var hasReceivedFirstProgress = false
        var consecutiveErrors = 0
        let progressTracker = ProgressTracker()
        await progressTracker.initialize(height: await syncManager.currentHeight)

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
                let target = await syncManager.targetHeight

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
                let finalHeight = await syncManager.currentHeight
                print("") // New line after progress bar
                print("")
                print("Sync complete!")
                print("Final height: \(finalHeight)")
                print("")
                print("Next step: Export headers")
                print("  swift run DogecoinNodeSync export --network \(networkName) --output <path>")
                return

            case .error(let error):
                consecutiveErrors += 1
                progressIndicator.stopSpinner()
                print("")
                print("Error (\(consecutiveErrors)/\(maxConsecutiveErrors)): \(error.localizedDescription)")

                if consecutiveErrors >= maxConsecutiveErrors {
                    print("")
                    print("Too many consecutive errors. Stopping sync.")
                    print("Current height: \(await syncManager.currentHeight)")
                    print("Progress has been saved. Run again to resume.")
                    await syncManager.stop()
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
                print("Current height: \(await syncManager.currentHeight)")
                print("Progress has been saved. Run again to resume.")
                await syncManager.stop()
                return

            case .interrupted:
                progressIndicator.stopSpinner()
                let currentHeight = await syncManager.currentHeight
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
            Task { await syncManager.stop() }
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

    func spvSync(_ manager: SPVSyncManager, progressUpdated progress: Double, height: Int32) async {
        continuation.yield(.progress(progress, height: height))
    }

    func spvSyncDidComplete(_ manager: SPVSyncManager) async {
        continuation.yield(.completed)
        continuation.finish()
    }

    func spvSync(_ manager: SPVSyncManager, didReceiveHeader header: BlockHeader, height: Int32) async {
        // Headers are logged via progress updates
    }

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        continuation.yield(.error(error))
    }
}
