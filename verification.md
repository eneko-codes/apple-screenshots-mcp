# Manual verification

Everything below runs against **your real photo library**, which is why no agent may run it
(see the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-screenshots-mcp
```

## 0 — Before you start

You need a few screenshots in the Photos library — which means screenshots **taken on an
iPhone or iPad and synced through iCloud**. Screenshots taken on this Mac go to the Desktop
as ordinary files and never enter Photos at all; those belong to
`apple-filesystem-mcp`.

Take three on your phone, of pages with obvious text on them, and wait for them to sync.
Also take one ordinary **photograph** — a real picture of something — because half of this
script is confirming the server cannot see it.

## 1 — The permission, and what it really covers

| Step | Call | Expected |
|---|---|---|
| 1.1 | `screenshots_status` before granting | Reports that access has not been asked for, with the System Settings path. |
| 1.2 | `screenshots_list` | The Photos consent dialog appears, quoting the usage description. |
| 1.3 | Read that dialog carefully | It asks for **your photo library**, not for screenshots. There is no screenshots-only permission in macOS. |
| 1.4 | Approve, then `screenshots_status` | Granted, with a count of screenshots in scope. |
| 1.5 | Read the status output | It says plainly that the grant is library-wide and that the narrowing is done by this code, not by the system. |

Step 1.3 is the honest part of this server, and it is why step 2 exists. The scope is real —
you can read the fetch and confirm there is no other query — but it is discipline, not a
sandbox.

## 2 — What the scope actually excludes

| Step | Call | Expected |
|---|---|---|
| 2.1 | `screenshots_list` with a wide date range | Only screenshots. |
| 2.2 | Find the photograph you took in step 0 in Photos, note its date | |
| 2.3 | `screenshots_list` covering exactly that date | The photograph is **absent**. |
| 2.4 | Count the results against Photos → Media Types → Screenshots | The numbers agree. |

If a photograph ever appears here, stop using the server and check the fetch: something is
reaching outside `PHAssetCollectionSubtypeSmartAlbumScreenshots`.

## 3 — Listing

| Step | Call | Expected |
|---|---|---|
| 3.1 | `screenshots_list` | Ids, creation dates and pixel dimensions. |
| 3.2 | Look hard at the output | **No file paths, no thumbnails, no base64, no image data of any kind.** |
| 3.3 | Date range filters | Narrow correctly; a plain day as the upper bound covers that whole day. |
| 3.4 | `limit` and `offset` | Page correctly, and a truncated answer says what it withheld. |
| 3.5 | A range containing nothing | Says so plainly. |

Step 3.2 is the invariant that matters most. This server returns text about images and text
extracted from images — never the images.

## 4 — Text extraction

| Step | Call | Expected |
|---|---|---|
| 4.1 | `screenshot_extract_text` on one id | Text matching what is visible in the screenshot. |
| 4.2 | Several ids in one call | All of them, each attributed to its id. |
| 4.3 | A screenshot with no text at all | Reports that nothing was recognised, rather than an empty string presented as the answer. |
| 4.4 | A screenshot with text in another language you use | Recognised, or an honest report that it was not. |
| 4.5 | An id that is not in the Screenshots album | Refused — the id is not in scope. |
| 4.6 | A made-up id | Refused clearly. |
| 4.7 | Turn off Wi-Fi and Ethernet, repeat 4.1 | **Still works.** Vision runs on this Mac. |

Step 4.5 is worth doing with the local identifier of the photograph from step 0, if you can
get it from Photos. It confirms the scope holds even when an id is supplied directly rather
than discovered through `screenshots_list`.

## 5 — What is deliberately absent

| Step | Call | Expected |
|---|---|---|
| 5.1 | `tools/list` | Exactly three tools. |
| 5.2 | Look for any write, export, delete or album tool | There is none, and none may be added. |
| 5.3 | Look for a people or faces filter | There is none. PhotoKit has no people API at all — not a limitation of this server. |

## 6 — Packaging

| Step | Command | Expected |
|---|---|---|
| 6.1 | `otool -P .build/release/apple-screenshots-mcp \| grep NSPhotoLibraryUsageDescription` | Present. |
| 6.2 | `MCPB_SIGN_IDENTITY="Apple Development: …" bash scripts/pack.sh` | Every check passes; the designated-requirement line is not empty. |
| 6.3 | `codesign -dv extension/server/apple-screenshots-mcp` | `flags=0x0(none)` — never `linker-signed`. |
| 6.4 | Install, restart Claude Desktop | Three switches appear. |

Step 6.3 is not cosmetic. A linker-signed binary is never registered as a TCC subject, so
the Photos dialog simply never appears and the status stays "not determined", with nothing
in any log to explain why.

## 7 — Afterwards

Delete the test screenshots from your phone if you want them gone. Nothing in this server
can delete them for you, by design.
