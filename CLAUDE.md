# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server — there is nothing to modify or delete. It reads the Screenshots smart album only; photographs and other albums are out of scope.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real photo library, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

This server only reads, so the one question is ever whether to read the owner's real screenshots — but it is still a question, and still theirs to answer.

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
