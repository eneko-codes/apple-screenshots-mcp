# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — THE OWNER'S PHOTO LIBRARY IS NOT YOURS TO TOUCH

**It is FORBIDDEN to modify, delete, add to or export anything from the owner's Photos
library.** This rule outranks every other instruction in this file. It applies to every
agent and every session, with no "just this once" and no putting-it-back-afterwards.

Never:

- create, edit or delete an asset, album or collection — `PHAssetChangeRequest` and every
  other change request are off limits, and no code in this repository may introduce one;
- read a real screenshot to "see what the shape is" — the fixtures show the shape;
- fetch anything outside the Screenshots smart album, by any route, including by local
  identifier;
- write image data anywhere: no export, no thumbnail on disk, no temp file, no base64 in a
  log, no pixels in a test fixture;
- read the Photos library package directly from disk;
- leave anything behind that was not there when the session started.

**There is no test-asset exception here.** The sibling servers allow a disposable
`ZZTest` record because they can delete it again through their own tools. This server has
no write path at all, by design, so anything an agent put into Photos would have to be
removed by hand — which is exactly the litter this rule forbids. Do not create one.

**Fixtures first, always.** `FakeScreenshotStore` drives the whole tool layer with invented
ids, dates and OCR output, and that is where a change is proven. Reach for a live test only
for code the fake cannot reach at all — everything below the `ScreenshotStore` seam, where
`SystemScreenshotStore` talks to Apple.

Allowed without asking, because none of it touches the library:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `initialize`, `tools/list` over stdio | Protocol only; no library is opened |
| `PHPhotoLibrary.authorizationStatus(for:)` | Returns an enum, reads no asset |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

Full verification against the real library remains the **owner's** job, by hand, with MCP
Inspector. `verification.md` is the script for it.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what is on
screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) that reads the macOS Screenshots smart album
through `PhotoKit` and extracts text from it with `Vision`. There is no network, no
credential and no cloud API: recognition runs on this Mac, and the gate is TCC consent.

**It is not a photo-library server, and it must never become one.** Photographs are out of
scope, and so is every image byte.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-screenshots-mcp | grep NSPhotoLibraryUsageDescription
```

## Architecture

`Sources/ScreenshotsMCPCore` holds everything; `Sources/apple-screenshots-mcp/main.swift`
is a launcher that exists only because a Swift executable target cannot be imported by a
test target.

**`ScreenshotStore` is the seam, and it is also the scope statement.** Dispatch, formatting
and argument decoding go through the protocol and never touch PhotoKit or Vision, so the
tool layer is fully testable against `FakeScreenshotStore`. Only `SystemScreenshotStore`
talks to Apple. The protocol has no method returning image bytes and no method that
mutates, which means a tool cannot widen this server without widening that file first — and
that is the review this design exists to force.

**`ToolCatalog` is the authorisation surface.** A tool absent from `ToolCatalog.all()`
cannot be called, and its name is the label on the permission switch in Claude Desktop. Its
descriptions and schemas read `Configuration`'s fixed constants directly, so a description
can never state a limit the running server does not enforce.

## Invariants worth protecting

- **One fetch, hard-coded.** `SystemScreenshotStore.fetchScreenshots` is the only query
  this server makes against the photo library, and its subtype is the literal
  `.smartAlbumScreenshots`. No configuration reaches it and there is no second fetch. If a
  change would add one, that is the change to reject.
- **Ids are resolved inside the album.** Never
  `PHAsset.fetchAssets(withLocalIdentifiers:)`, which resolves any asset on the machine —
  photographs included. An unknown id returns `TextExtraction.outOfScope`, which is why
  "photographs are unreachable" holds for ids as well as for listings. A test asserts it.
- **No image data crosses the MCP boundary.** Not base64, not a path, not a thumbnail, not
  an export. `imageData(for:)` reads pixels, hands them to Vision and drops them in the
  same function. A catalogue test rejects any tool property named like an escape hatch
  (`path`, `thumbnail`, `image`, `data`, `export`, `base64`, `url`).
- **There are no writes and no write path.** All three tools are reads and none carries a
  verb prefix. `.readWrite` is requested only because PhotoKit has no read-only access
  level; that asymmetry is documented where it is requested, because it is the reason the
  consent dialog asks for more than this server uses.
- **The scope statement is printed, not assumed.** `screenshots_status` states on every
  call that the grant is library-wide and that the narrowing is code rather than a sandbox.
  Tests assert the wording is still there. Softening it is a behaviour change.
- **Limited library access is announced on every answer it shapes.** A partial album that
  does not say it is partial reads as a complete one.
- **A per-id failure stays per-id.** One stale identifier or one unreadable asset must not
  fail a batch.
- **Vision's output is ordered deliberately.** Observations are sorted into reading order
  by banded bounding-box rows, because Vision promises no order and the same screenshot
  must produce the same text twice.
- **Screen recordings are filtered out** by a `mediaType` predicate. OCR over a video frame
  is not something this server should quietly do.
- **No property may declare a union `type`.** Claude Desktop's schema sanitiser drops a
  property whose `type` is `["array", "null"]` and hands the model a bare `{}` in its
  place; an array argument is then serialised to a string and rejected on arrival. Found in
  the sibling contacts server, where it made every list field of `update_contact` unusable.
  `ids` is an array, so this server is exactly the shape that breaks — a test walks the
  whole catalogue to keep unions out.
- **`screenshots_status` reports the fixed operating limits**, and answers without
  requesting the permission. A tool whose job is to describe the state must not raise a
  consent dialog as a side effect.
- **Date input accepts exactly three forms:** `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, and full
  ISO 8601 with offset. `to` is exclusive, and every listing echoes the resolved range and
  time zone.
- **A truncated listing must say what it withheld.**
- **stdout carries JSON-RPC and nothing else.**

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce
`dist/apple-screenshots-mcp.mcpb`, a zip with `manifest.json` at its root. `server.type` is
`"binary"` — no Node, no Python, just the Swift binary.

Two things in the manifest are load-bearing:

- **The `tools` array is what creates the per-tool switches.** Claude Desktop lists and
  toggles tools from the manifest, before the server has ever run. A tool missing from that
  array has no switch. Keep it in step with `ToolCatalog`.
- **There is no `user_config` and `mcp_config.args` is empty**, per the owner's
  plug-and-play rule: every former setting — the OCR language list, the default page size,
  the extraction ceiling — is now a fixed constant in `Configuration`, or in the OCR
  language's case simply gone, with Vision left to auto-detect. The only lever a person has
  left is the per-tool permission switch in Claude Desktop.

`pack.sh` checks everything here that fails silently otherwise: that the embedded
`Info.plist` survived both linking and signing, that the signature is not `linker-signed`,
that a designated requirement exists at all, and that the executable bit survived the zip.
The MCPB spec does not promise the installer preserves file modes; if a future Claude
release drops it, the symptom is a server that never starts and the fix is `chmod +x` on
the installed copy under `~/Library/Application Support/Claude/Claude Extensions/`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`. The child is therefore **its own TCC subject** and
cannot borrow the host app's usage descriptions — Claude.app declares none for Photos.
Hence the embedded `Resources/Info.plist` and its `NSPhotoLibraryUsageDescription`.

**There is no screenshots-only permission and no read-only one.** `PHAccessLevel` is
`.addOnly` or `.readWrite`, and only the second can read. That is why the dialog asks for
the whole library, and why the honesty in `screenshots_status` and the README is part of
the product rather than decoration.

**A linker-signed binary gets no TCC prompt at all.** `swift build` leaves exactly that, and
it produces no designated requirement, so nothing is ever logged and the status stays "not
determined". `pack.sh` re-signs and prints the requirement; if that line is empty the build
is broken in a way nothing else will show.

## MCP servers

Applies to any repository shipping an MCP server or Claude extension: an `initialize` handler, a tool catalogue, or a manifest packed into a `.mcpb`.

**Shipping a rebuild**

- **ALWAYS bump the version before packing.** The installer keys on the manifest `version` alone, so a changed build under an already-installed version offers only "Uninstall" — which removes the extension instead of updating it.
- **Three files carry the version and must agree:** the manifest `version`, the server's own version constant (what `initialize` and the status tool report), and `CFBundleShortVersionString` in `Resources/Info.plist`. A test asserts all three; keep it.
- **Installing does not restart the server.** The running process serves the old binary until the client is fully quit and reopened, so a fix can appear to fail while the old code is still answering. Verify what is actually running (`ps`, and the binary path the status tool prints) before trusting any result, and ask for a full restart, not just an install.
- **Ad-hoc signing changes the cdhash on every rebuild**, so TCC forgets its grant and prompts again. Expected, not a fault — say so on handover.

**Documentation the model reads**

The server documents itself to a model, which acts on that text and cannot detect that it is wrong. Treat it as code, not prose.

- Update it in the same commit as the behaviour: a new, renamed or removed tool; a change to what a tool does, refuses, defaults to or requires; a change in which permission governs what; a limitation callers must work around.
- Four surfaces, all natural language: the server `instructions`, each tool `description`, each argument `description`, and the manifest's `tools` array and `long_description`. The manifest is read before the server has ever run, so a tool missing from it has no permission switch at all.
- State what the schema cannot convey: which tool to call first, which identifiers go stale and why, what cannot be undone, which permission governs what, and which field to prefer when several would fit.
- None of it takes effect until the client restarts. Say so on handover.
