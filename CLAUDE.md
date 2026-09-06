# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. It only reads the Screenshots smart album; photographs and other albums are out of scope.

## What this is

A local MCP server (Swift 6, stdio transport) that reads the macOS Screenshots smart album through `PhotoKit` and extracts text from it with `Vision`. No network, no credential, no cloud API — recognition runs on this Mac, gated by TCC consent.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-screenshots-mcp | grep NSPhotoLibraryUsageDescription
```
