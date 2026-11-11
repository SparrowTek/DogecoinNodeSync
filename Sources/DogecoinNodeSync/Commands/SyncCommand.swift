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
    var network: NetworkOption = .mainnet

    @Option(name: [.short, .long], help: "Custom storage directory for headers")
    var storage: String?

    func run() async throws {
        let storageURL = try headerStorageDirectory(custom: storage, network: network)

        print("Starting header sync for \(network.rawValue)...")
        print("Storage: \(storageURL.path)")

        // Opens the header database, so the height below is the height on
        // disk — not the -1 of a database nobody has looked at yet.
        let syncManager = try await SPVSyncManager.create(
            network: network.value,
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

        let noProgressTimeout: TimeInterval = 300

        var hasReceivedFirstProgress = false
        let progressTracker = ProgressTracker()
        await progressTracker.initialize(height: startingHeight)

        // Start a background task to check for progress timeout
        let timeoutTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))

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
                _ = await progressTracker.recordProgress(height: height)

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
                print("  swift run DogecoinNodeSync export --network \(network.rawValue) --output <path>")
                return

            case .error(let error):
                // The kit deals with trouble from single peers itself. What
                // it reports is an error it cannot go on from — the header
                // database could not be read — and it has stopped.
                progressIndicator.stopSpinner()
                print("")
                print("Sync failed: \(error.localizedDescription)")
                print("Headers stored so far are kept. Run again to resume.")
                throw ExitCode.failure

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

    func spvSync(_ manager: SPVSyncManager, didEncounterError error: Error) async {
        continuation.yield(.error(error))
        continuation.finish()
    }
}
