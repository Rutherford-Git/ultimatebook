# Inkbook roadmap

Backlog drawn from field notes on Goodnotes (web app, Oct 2026) and Inkbook's own diagnostics.
Ordered by value for effort. Status: ✅ done · 🔜 next · ⬜ open.

## Where Inkbook stands

| Area | Goodnotes (field notes) | Inkbook |
|---|---|---|
| Frame time while drawing | 4.2 ms median (240 Hz screen) | 8.34 ms steady (120 Hz iPad) |
| Finishing a stroke | 48 ms median, 120 ms worst | 0.34 ms median, 1.7 ms max |
| Long main-thread stalls | 2 (86 ms max) | Full-page redraws, 53 ms max — see P1 |
| Input rule | Stylus disables mouse/finger | Pencil-only by default, toggle in title menu |
| Selection actions | Hidden for mouse users | Bar on screen |

## Quick wins

1. ✅ **Search inside notebooks.** Handwriting, typed text and PDF text. Library search covers every notebook (`search.json` per bundle); "Find in notebook" covers the open one. PDF text is extracted at import, and on open for older imports.
2. ✅ **Save status.** Title menu shows "Saved 2 minutes ago" / "Saving…". A failed save shows "Couldn't save your edits. Trying again…", retries after 2 s, doubling up to 30 s, then confirms "Saved".
3. ✅ **Pen tuning with live preview.** Stabilization (pen, highlighter) and pressure sensitivity (pen), stored per preset. The preview runs a shaky sample stroke through the real smoothing and renderer.
4. ✅ **Tooltips.** Every icon button has a name and a pointer tooltip. Keep first-run prompts to one at most.
5. ✅ **Straight-line highlighter.** Toggle in highlighter options.

## Next (medium)

6. 🔜 **Crash-safe edit journal.** Append-only stroke journal replayed on launch. Save inside `beginBackgroundTask` on resign-active and background. Kill-and-relaunch self-test.
7. ⬜ **Hold to snap shapes.** Line, circle, rectangle, arrow.
8. ⬜ **Start screen and paper.** Templates instead of an empty library, one-tap quick note. More papers: Cornell, legal, columns, music. Paper size and orientation.
9. ⬜ **Tape.** Covers content until tapped (flashcards). Straight mode and "remove all from page".
10. ⬜ **Laser pointer.** Dot or fading line.

## Larger

11. ⬜ **Lasso filters and rectangle lasso.** Handwriting-to-text from the selection bar.
12. ⬜ **Customizable toolbar.**
13. ⬜ **Grainy pencil texture.** First real case for Metal or textured stamps.
14. ⬜ **Record and summarize.** Audio, with a summary from the agent only when asked.

## Performance

- P1 ⬜ **Full-page redraws.** About 30 ms at 80 strokes, 53 ms max on device. Log the trigger (zoom end, undo, page switch, layer change). Make undo redraw only what changed. Use a tiled or background-rendered page cache for zoom.
- P2 ⬜ **Signposts.** Save duration, save-queue depth and recognition start, so each hitch has a cause.
- Metal: hold until the redraw profile shows a need.

## Avoid (Goodnotes' weak spots)

- Interruptions before the first stroke (terms, tips, "open in app").
- Icons without names or tooltips.
- Silent failure in the background — always say what is happening.
- Paywalls or a marketplace inside the writing flow.
