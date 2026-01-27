# DogecoinNodeSync

A command-line tool for managing Dogecoin block headers. Sync headers from the peer network, export them for bundling into the Avocadoge app, and verify/inspect header cache files.

## Installation

```bash
cd Tools/DogecoinNodeSync
swift build -c release
```

The built binary will be at `.build/release/DogecoinNodeSync`.

## Commands

| Command   | Description                                      |
|-----------|--------------------------------------------------|
| `sync`    | Download headers from Dogecoin peers (default)   |
| `export`  | Export headers to a portable bundle file         |
| `verify`  | Validate a header cache file                     |
| `inspect` | Print info about a header cache file             |

---

## sync

Download block headers from the Dogecoin peer-to-peer network using SPV.

```bash
swift run DogecoinNodeSync sync [OPTIONS]
```

### Options

| Option                    | Description                              | Default                                          |
|---------------------------|------------------------------------------|--------------------------------------------------|
| `--network <network>`     | Network to sync (`mainnet` or `testnet`) | `mainnet`                                        |
| `-s, --storage <path>`    | Directory to store synced headers        | `~/Library/Caches/DogecoinKit/headers/<network>` |

### Examples

```bash
# Sync mainnet to default location
swift run DogecoinNodeSync sync

# Sync mainnet to a custom directory
swift run DogecoinNodeSync sync --storage ~/Desktop/dogecoin-headers

# Sync testnet
swift run DogecoinNodeSync sync --network testnet

# Sync testnet to custom location (short form)
swift run DogecoinNodeSync sync --network testnet -s /path/to/headers
```

### Notes

- The initial sync downloads ~6 million headers and takes several hours
- Progress is saved incrementally - interrupt with Ctrl+C and resume later
- The system will not sleep during sync
- After 10 consecutive errors or 5 minutes without progress, sync stops automatically

---

## export

Export synced headers to a portable bundle file for use in the Avocadoge iOS app.

```bash
swift run DogecoinNodeSync export --output <path> [OPTIONS]
```

### Options

| Option                    | Description                                        | Default                                          |
|---------------------------|----------------------------------------------------|--------------------------------------------------|
| `--output <path>`         | Output directory for exported files **(required)** | —                                                |
| `--network <network>`     | Network to export (`mainnet` or `testnet`)         | `mainnet`                                        |
| `--storage <path>`        | Source header cache location                       | `~/Library/Caches/DogecoinKit/headers/<network>` |
| `--format <format>`       | Export format (`sqlite` or `lzfse`)                | `sqlite`                                         |

### Examples

```bash
# Export mainnet headers to SQLite format
swift run DogecoinNodeSync export --output ./headers

# Export to LZFSE compressed format (smaller file size)
swift run DogecoinNodeSync export --output ./headers --format lzfse

# Export testnet headers
swift run DogecoinNodeSync export --network testnet --output ./testnet-headers

# Export from a custom source location
swift run DogecoinNodeSync export --output ./headers --storage ~/Desktop/dogecoin-headers
```

### Output Files

The export creates two files in the output directory:
- `headers.sqlite` (or `headers.bin.lzfse`) — The header data
- `metadata.json` — Metadata including header count, tip hash, and checksum

---

## verify

Validate a header cache file to ensure integrity.

```bash
swift run DogecoinNodeSync verify <path>
```

### Arguments

| Argument  | Description                                                        |
|-----------|--------------------------------------------------------------------|
| `<path>`  | Path to `headers.sqlite`, `headers.bin.lzfse`, or their directory  |

### Examples

```bash
# Verify a header cache directory
swift run DogecoinNodeSync verify ./headers

# Verify a specific file
swift run DogecoinNodeSync verify ./headers/headers.sqlite
```

### Checks Performed

- File size matches metadata
- SHA256 checksum matches
- Header count matches
- Tip height and hash match
- Chain linkage is valid (sampled verification)

---

## inspect

Print basic information about a header cache file.

```bash
swift run DogecoinNodeSync inspect <path>
```

### Arguments

| Argument  | Description                                                        |
|-----------|--------------------------------------------------------------------|
| `<path>`  | Path to `headers.sqlite`, `headers.bin.lzfse`, or their directory  |

### Example

```bash
swift run DogecoinNodeSync inspect ./headers
```

### Sample Output

```
Header cache:
  Format: SQLite
  Version: 2
  Network: mainnet
  Headers: 6,123,456
  Tip: 6123455 82a1b3c4d5e6f7...
  Generated: 2024-01-15T10:30:00Z
  Database size: 523456789 bytes
  Checksum SHA256: abc123...
```

---

## Typical Workflow

1. **Sync headers** from the Dogecoin network:
   ```bash
   swift run DogecoinNodeSync sync
   ```

2. **Export headers** for bundling into the iOS app:
   ```bash
   swift run DogecoinNodeSync export --output ./headers
   ```

3. **Verify the export** (optional but recommended):
   ```bash
   swift run DogecoinNodeSync verify ./headers
   ```

4. **Inspect the export** to check details:
   ```bash
   swift run DogecoinNodeSync inspect ./headers
   ```

---

## Storage Locations

| Type           | Default Path                                           |
|----------------|--------------------------------------------------------|
| Synced headers | `~/Library/Caches/DogecoinKit/headers/<network>/`      |
| Exported files | User-specified via `--output`                          |

---

## Export Formats

| Format   | File                  | Best For                                    |
|----------|-----------------------|---------------------------------------------|
| `sqlite` | `headers.sqlite`      | Fast loading, random access, larger size    |
| `lzfse`  | `headers.bin.lzfse`   | Smaller bundle size, sequential access only |

SQLite is recommended for the iOS app due to faster load times.
