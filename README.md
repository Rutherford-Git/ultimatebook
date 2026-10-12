# Inkbook

A local-first iPad notebook that combines **Goodnotes-style notes** (pages, vector ink, highlighter,
text, images, PDF backgrounds) with **Procreate-style painting** (raster layers, pressure brushes,
opacity and blend modes) — plus an **optional, approval-gated agent** you can point at your notebook.

- **No cloud.** Notebooks are plain folders in the app's Documents (visible in Files). The app has no
  sync, accounts or analytics.
- **Agent is opt-in.** Off by default. When you enable it and save your own API key (stored in the
  device Keychain), the agent can read pages and *propose* notes and highlights. Every change needs
  your approval and lands on a separate **Agent layer** you can hide or delete.
- **Imports Goodnotes.** `.goodnotes` files import with ink, colors, highlighter, images, text boxes,
  PDF/image backgrounds and handwriting transcripts. Anything not converted is listed in the import
  report. Format notes: [docs/GOODNOTES_FORMAT.md](docs/GOODNOTES_FORMAT.md).

## Layout

| Path | What | Builds on |
|---|---|---|
| `Sources/InkbookCore/Model` | Notebook → Page → Layer (vector / raster / agent) → Element | any |
| `Sources/InkbookCore/Storage` | `.inkbook` bundle: `manifest.json`, `raster/*.png`, `assets/*`; atomic writes, schema versioning | any |
| `Sources/InkbookCore/Brush` | Pressure curve, smoothing, raster dab spacing, vector eraser hit-testing | any |
| `Sources/InkbookCore/Import/Goodnotes` | Protobuf wire reader, Apple LZ4, `tpl` decoder, importer + report | any |
| `Sources/InkbookCore/Agent` | Tool definitions, approval protocol, Messages API client (raw HTTPS), tool-use loop | any |
| `App/Inkbook` | SwiftUI/UIKit iPad app: canvas, layers, library, agent panel, Keychain | iOS 17+ |

The core is platform-independent and tested on Linux and macOS. The app layer is a thin shell over it.

## Build

```bash
swift test                       # core tests (Linux or macOS)
brew install xcodegen            # once, on your Mac
xcodegen generate                # creates Inkbook.xcodeproj from project.yml
open Inkbook.xcodeproj           # run the "Inkbook" scheme on an iPad or iPad simulator
```

Check the importer against a real notebook (never committed):

```bash
INKBOOK_GOODNOTES_SAMPLE=~/Downloads/MyNotes.goodnotes INKBOOK_SVG_OUT=/tmp/pages swift test --filter testRealGoodnotesFileWhenProvided
```

## Install on iPad without a Mac (sideload)

Every push to `main` builds an unsigned `Inkbook.ipa` on GitHub's macOS runners and publishes it as
the **latest** release (Releases → *Inkbook (latest main build)*; also attached to each CI run as
the `Inkbook-ipa` artifact).

1. Download `Inkbook.ipa` from the release.
2. Install it with **Sideloadly** (Windows/macOS) or **AltStore** (Windows + iPad), which sign it with
   your Apple ID.
3. On the iPad: Settings → General → VPN & Device Management → trust your Apple ID. On iPadOS 16+
   also turn on Settings → Privacy & Security → Developer Mode.
4. With a free Apple ID the app expires after 7 days; refresh it from AltStore or re-install with
   Sideloadly. Notebooks stay in the app's Documents folder across re-installs if the bundle ID stays
   the same.

## Agent bridge

| Tool | Effect |
|---|---|
| `list_pages` | Page sizes, element counts, text previews |
| `read_page` | Text boxes, handwriting transcript, element positions; optional page image |
| `add_note` | Proposes a sticky note → approval sheet → Agent layer |
| `add_highlight` | Proposes a highlight rectangle → approval sheet → Agent layer |

Defaults: model `claude-opus-5-5`, effort `medium` (both changeable in Agent settings), adaptive
thinking, server-side refusal fallback enabled (`fallbacks: "default"`, beta header
`server-side-fallback-2026-07-01`). Assistant content is echoed back unchanged, so thinking blocks
stay valid. Tools use `strict: true` schemas, and the loop runs tools one at a time so approvals arrive
in order.

## Status

- Core: implemented and tested (`swift test`; the real-file import test is opt-in).
- iPad app: runs on device (sideloaded build). CI compiles it for the simulator and builds the IPA.
- Drawing: pressure pens render as filled variable-width outlines. Committed ink is cached and only
  changed areas repaint; the live stroke is drawn on a separate overlay with predicted touches.
- Lasso (vector and agent layers): select, drag to move, duplicate, delete.
- PDF: import (one page per PDF page, as background) and export (vector PDF via the share sheet).
- Handwriting recognition: on-device (Vision), a few seconds after you stop writing on a page; the
  transcript feeds the agent's `read_page`.
- Next steps: Metal brush engine for textured/large raster brushes, raster lasso, thumbnails/search.
