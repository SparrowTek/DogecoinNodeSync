# DogecoinNodeSync

A CLI tool that syncs Dogecoin block headers using SPV (Simplified Payment Verification). Once synced, headers can be exported using HeaderCacheTools for bundling into the Avocadoge app.

## Usage

```bash
cd Tools/DogecoinNodeSync

# Sync mainnet (default)
swift run DogecoinNodeSync

# Sync testnet
swift run DogecoinNodeSync --network testnet

# Custom storage path
swift run DogecoinNodeSync --storage /path/to/headers
```

## After Sync

Once sync completes, export headers using HeaderCacheTools:

```bash
cd Tools/HeaderCacheTools
swift run HeaderCacheTools export --network mainnet --output <path>
```

## Notes

- The initial sync downloads ~6 million headers and takes several hours
- Progress is saved incrementally to disk
- Interrupt with Ctrl+C and resume later - progress is preserved
- The system will not sleep during sync
