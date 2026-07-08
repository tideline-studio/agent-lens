# agent-lens

A macOS daemon + CLI for code diagnostics and linting. The entire interface is: **give it a list of files, get structured results back.** What produces that list and what consumes the results is entirely up to you.

If you need a full editor experience for agents, see **[aifed](https://github.com/ImitationGameLabs/aifed)**.

**Requirements:** macOS 15, Swift 6.

---

## How it works

`alensd` runs as a background daemon rooted at a directory. It holds live LSP sessions so language servers stay warm between queries. `alens` is a thin client that sends a command over a Unix socket and prints JSON.

```
your script / agent / CI / editor hook
        │
        │  list of file paths
        ▼
      alens  ──── Unix socket ────▶  alensd
                                        ├── LSP session (sourcekit-lsp, ts-server, …)
                                        └── linter process (swiftlint, eslint, ruff, …)
        │
        │  JSON results, per file
        ▼
   post-processing
```

The daemon is the only stateful part. The CLI is stateless — run it from a shell, a Makefile, an AI agent loop, a git hook, or anything else that can exec a process.

---

## Install

```sh
swift build -c release
cp .build/release/alensd /usr/local/bin/
cp .build/release/alens  /usr/local/bin/
```

---

## Usage

Start the daemon once per project root:

```sh
alensd --dir /path/to/project
```

Then query it with any list of files:

```sh
# Files from a glob
alens diagnose Sources/**/*.swift

# Files from git
alens diagnose $(git diff --name-only HEAD)

# Files from find
alens lint $(find . -name "*.py" -not -path "./.venv/*")

# Single file
alens check Sources/App/main.swift

# Daemon health
alens status

# Shut down
alens stop
```

All output is JSON. Wire it into `jq`, log it, feed it to an agent, diff it in CI — the tool does not care.

---

## Commands

| Command | Input | Output |
|---|---|---|
| `diagnose` | list of files | LSP diagnostics per file (errors, warnings, ranges) |
| `lint` | list of files | linter stdout per file (raw JSON from the linter) |
| `check` | list of files | both, in one round-trip |
| `status` | — | readiness state and uptime per language server |
| `start` | idle timeout, log level | ack |
| `stop` | — | ack |

`check` is not a special mode — it is `diagnose` + `lint` returned together so you do not pay two socket round-trips.

---

## Wire protocol

Commands travel as versioned, length-prefixed JSON frames over a Unix socket at `/tmp/alensd-<hash>.sock`. The socket path is derived from the project root, so multiple daemons for different roots coexist without configuration.

Protocol version is `1`. A version mismatch returns `ErrorCode.versionMismatch` before any work is done. All responses carry the originating request ID so concurrent callers can match replies.

---

## Language servers

The daemon routes each file to the right LSP session by extension.

| Language | Extension(s) | Server |
|---|---|---|
| Swift | `.swift` | `sourcekit-lsp` |
| TypeScript | `.ts` `.tsx` | `typescript-language-server` |
| JavaScript | `.js` `.jsx` `.mjs` `.cjs` | `typescript-language-server` |
| Python | `.py` `.pyi` | `pyright-langserver` |
| Go | `.go` | `gopls` |
| Rust | `.rs` | `rust-analyzer` |

Servers must be on `PATH`. Files with unrecognised extensions return `ReadinessState.unsupported`.

Both language servers and linters are configured in a single `.alens.json` at the project root.

### Customising language servers

By default the daemon auto-detects which servers to run by scanning project markers (`Package.swift`, `tsconfig.json`, etc.). Adding an `lspServers` key to `.alens.json` overrides detection entirely — only the listed servers are launched.

```json
{
  "lspServers": {
    "swift": {
      "command": "sourcekit-lsp",
      "args": [],
      "env": { "SOURCEKIT_LOGGING": "0" }
    },
    "typescript": {
      "command": "typescript-language-server",
      "args": ["--stdio"]
    }
  }
}
```

An empty `lspServers: {}` deliberately runs no servers.

---

## Linters

| Language | Tool |
|---|---|
| Swift | `swiftlint lint --reporter json` |
| TypeScript / JavaScript | `eslint --format json` |
| Python | `ruff check --output-format json` |
| Go | `golangci-lint run --out-format json` |

Override per project via the `linters` key in `.alens.json`:

```json
{
  "linters": {
    "swift": {
      "command": "swiftlint",
      "args": ["lint", "--reporter", "json", "$FILE"],
      "fileField": "file"
    },
    "python": {
      "command": "ruff",
      "args": ["check", "--output-format", "json", "$FILE"],
      "fileField": "filename"
    }
  }
}
```

`$FILE` expands to all paths in the batch — one process runs for the whole batch, and the output is split back into per-file results. `fileField` is a dotted key path within each result entry that names the file. `resultsKey` points to a nested results array when the linter wraps output (e.g. `"Issues"` for golangci-lint).

---

## References

- [Language Server Protocol 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/) — including pull diagnostics (`textDocument/diagnostic`)
- [ChimeHQ/LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) — Swift LSP types
- [ChimeHQ/JSONRPC](https://github.com/ChimeHQ/JSONRPC) — JSON-RPC session
- [apple/swift-nio](https://github.com/apple/swift-nio) — NIO frame codec (IPC layer)
- [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) — subprocess spawning
- [pointfreeco/swift-dependencies](https://github.com/pointfreeco/swift-dependencies) — dependency injection
- [pointfreeco/swift-clocks](https://github.com/pointfreeco/swift-clocks) — injectable clocks for deterministic tests
- [SwiftLint](https://github.com/realm/SwiftLint), [ESLint](https://eslint.org), [Ruff](https://docs.astral.sh/ruff/), [golangci-lint](https://golangci-lint.run)
