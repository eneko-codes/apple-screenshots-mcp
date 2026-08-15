<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-screenshots-mcp icon">
</p>

# apple-screenshots-mcp

A local MCP server, written in Swift, that lets Claude read **the text in your
screenshots**. It reaches the macOS Screenshots smart album through `PhotoKit` and runs
`Vision` text recognition over it. It ships as a Claude extension.

No network, no credentials, no cloud API. Recognition happens on this Mac; iCloud is only
the sync engine that may hold the original, and the gate is macOS **privacy consent**
rather than authentication.

**This is not a photo-library server.** Photographs are never listed and never read. No
image data of any kind crosses the boundary — the tools return metadata and text.

Not affiliated with or endorsed by Apple Inc.

## Be clear about what the permission covers

macOS grants Photos access at the level of the **whole library**. There is no
screenshots-only permission, and there is no read-only one either: PhotoKit offers
`.addOnly` (write) and `.readWrite`, so anything that reads must hold the level that also
permits writing. The system dialog will say Claude wants access to your photo library, and
it means it.

**The narrowing to screenshots is done by this server's code, not by the operating
system.** That is a real restriction and it is meant to be checked rather than trusted:

- there is **exactly one query** against the library in the whole repository, in
  `Sources/ScreenshotsMCPCore/SystemScreenshotStore.swift`, and its subtype is the literal
  `.smartAlbumScreenshots`;
- ids are resolved **inside that album**, never through
  `PHAsset.fetchAssets(withLocalIdentifiers:)`, so an id naming a photograph does not
  resolve — it comes back as out of scope;
- the store protocol that everything else talks to has **no method returning image bytes
  and no method that writes**, so a new tool cannot widen the server without widening that
  file first.

It is still discipline holding the line, not a sandbox. `screenshots_status` says exactly
this, in those words, on every call.

## What never crosses the boundary

- No image data: no base64, no file paths, no thumbnails, no exports, no QuickLook.
- No writes. There is no `PHAssetChangeRequest` anywhere in this repository and no tool
  that could carry one. The library cannot be altered by this server.
- No photographs, by listing or by id.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `screenshots_status` | read | Permission state, how many screenshots are in scope, the fixed operating limits, and what the grant actually covers. Reads no image. |
| `screenshots_list` | read | Screenshots newest first: id, capture time, pixel size. Optional date range, limit, offset. Nothing else. |
| `screenshot_extract_text` | read | Vision OCR over several ids at once. Returns text per id. The only tool that reads content. |

Three tools, all reads, so none carries a `create_`/`update_`/`delete_` prefix — the
convention the sibling servers use for writes. There is nothing here to prefix.

## The rules worth knowing before you use it

**Where your screenshots actually are.** Screenshots taken with ⌘⇧3 or ⌘⇧4 land on the
Desktop as ordinary **files** and never reach Photos. This album holds the ones that came
from an iPhone or iPad over iCloud Photos, or that you added to Photos by hand. If
`screenshots_status` reports a count of zero on a machine full of screenshots, that is
why — and a file-based server is the right tool for the Desktop ones.

**Dates take exactly three forms:**

```
2026-08-12                  a whole day, local time
2026-08-12T09:00            local time
2026-08-12T09:00:00+02:00   explicit offset
```

`to` is **exclusive**, and every listing echoes the range and time zone it resolved, which
is how an off-by-one-day is caught before it becomes an answer.

**OCR is a reading, not a transcript.** Vision misreads small, stylised and low-contrast
type. Text that came out of this server should be attributed to the recognition, not
quoted as if it were the screenshot itself.

**Vision detects the language on its own.** There is no language list to set: recognition
runs with Vision's own automatic language detection on every call, whatever language the
screenshot is actually in.

**A bad id costs you that id, not the call.** Text extraction returns one outcome per id,
so a stale identifier among five still leaves you the four that worked.

**Limited library access is honoured but announced.** If the Photos grant is a limited
selection rather than the full library, every answer built on it carries a note saying so.
A partial album that does not say it is partial reads as an empty one.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-screenshots-mcp.mcpb`. It fails loudly rather than shipping a bundle
that would silently refuse to work.

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-screenshots-mcp.mcpb` with Claude. Then **quit Claude Desktop completely
and reopen it** — reinstalling does not replace a server process that is already running,
and the old one keeps answering.

### 3. Grant the permission

Call `screenshots_status`; the first call that needs data raises the consent dialog. The
entry appears as **apple-screenshots-mcp** under
System Settings → Privacy & Security → Photos
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Fotos).

Choose **Full Access** if you want the whole album readable. Limited Access works too and
the server says so on every answer, but it will hide screenshots you can plainly see in
Photos.

The binary is **its own privacy subject**: Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so the
child cannot inherit the host app's permissions — and Claude.app declares no Photos usage
description anyway. Hence the `Info.plist` embedded at link time.

If no dialog ever appears:

```bash
otool -P extension/server/apple-screenshots-mcp | grep NSPhotoLibraryUsageDescription
```

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-screenshots-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds, so the grant is not re-requested after every build. `pack.sh`
prints the requirement on every build, which is what makes a silent regression to ad-hoc
visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so moving
between ad-hoc, Apple Development and Developer ID each costs one fresh round of consent.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
PhotoKit and Vision are reached directly and need no entitlements.

## Tool switches

There is nothing to configure: no settings form, no `user_config` in the manifest. The
only lever is the per-tool switch Claude Desktop shows for every extension, because the
bundle declares all three tools in its manifest — that is where policy lives, not in this
code. Turning off `screenshot_extract_text` leaves a server that can only say what
screenshots exist and never reads one.

Page size, the extraction ceiling, and Vision's automatic language detection are fixed in
`Configuration` rather than left open-ended. `screenshots_status` reports the limits
actually in force, which is the quickest way to check what a running server enforces.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```json
{
  "mcpServers": {
    "Apple Screenshots": {
      "command": "/absolute/path/to/apple-screenshots-mcp/.build/release/apple-screenshots-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide, and `screenshots_status` prints the binary path precisely so you can
tell which one answered.

## Known limits

- **PhotoKit has no people or faces API**, and no captions, titles or keywords. There is
  no header for any of it. Nothing here can search by who is in a screenshot.
- **Identifiers are not durable.** Rebuilding or restoring a photo library regenerates
  them, which is why every workflow starts with a listing.
- **Text extraction is the slow part.** Each screenshot is decoded at full resolution and
  put through a recognition pass, and an original that lives only in iCloud is downloaded
  first. Bound a listing by date and extract from a few ids rather than the album.
- **Screen recordings are excluded** by a media-type filter, so a video that somehow landed
  in the album is never fed to OCR.

## Development

```bash
swift build
swift test
```

35 tests, all against an in-memory fake. They need no permission and never touch a real
photo library — see `CLAUDE.md`, whose first section is the rule that makes that
non-negotiable.

Manual verification against the live library is the owner's job; `verification.md` is
the script for it.

## Licence

MIT.
