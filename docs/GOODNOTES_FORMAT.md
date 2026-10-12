# Goodnotes `.goodnotes` format (reverse-engineered from one sample)

Sample: `Physics_2.goodnotes` (29 MB, 118 ZIP entries, 31 pages, 6,087 elements).
Status markers: **[verified]** = decoded and checked against every record or by rendering;
**[inferred]** = consistent with the sample, not proven; **[unknown]** = seen but not decoded.

## 1. Container [verified]
Standard ZIP (deflate). Layout:

| Path | Content |
|---|---|
| `index.events.pb` | CRDT-style event log: document, pages, templates, layers |
| `index.notes.pb` / `index.attachments.pb` / `index.search.pb` | `{1: id, 2: "dir/id"}` manifests |
| `notes/<noteId>` | Ink/content layer for one page (empty file = blank page) |
| `attachments/<id>` | Raw JPEG / PNG / PDF (backgrounds, pasted images) |
| `search/<noteId>` | Handwriting recognition for that layer (5-byte file = none) |
| `thumbnail.jpg` | Cover thumbnail |
| `schema.pb` | `08 23` → schema version **35** [inferred] |
| `document.info.pb` | empty in sample |

## 2. Framing [verified]
- `index.*.pb` and `notes/*`: **stream of varint-length-prefixed protobuf messages**.
- `search/*`: **one** protobuf message (no prefix).
- Binary blobs inside fields use **Apple `compression_lz4` framing**:
  `"bv41" u32 rawSize u32 encSize <LZ4 block>` … / `"bv4-" u32 size <raw>` … / `"bv4$"` end.
- Versioned registers look like `{1: value, 2: {1: counter, 2: hash}}` (LWW register) [inferred].
- Common trailer fields: `f64 timestamp(ms)`, `id` (change id), constant `6899196457523149253` (device/replica id) [inferred], `24` (format minor) [inferred].

## 3. `index.events.pb` — entity records
Each message: `{1: entityId, <TYPE>: body}`; the body's field number is the entity type.

| Type | Meaning | Key fields |
|---|---|---|
| 30 | Document [verified] | `2.1` title (`"Physics 2"`), `6.1` initial |
| 54 | **Page** [verified] | `3.1` → template id, `4.1` **fractional-index sort key** (e.g. `"4u8J81"`), `17` paper colors RGBA |
| 2 | Paper template [verified] | `8` size `{1: w, 2: h}` f32 (1122×1452 / 760×1077), `9` background name or attachment id, `18` margins rect |
| 104 | Layer created; id == `notes/<id>` [verified] | `13 'auto'` |
| 105 / 102 / 103 | search-index / content-saved / misc bookkeeping [inferred] | |
| 6, 56, 10 | template-page refs, page groups, last-viewed page (`"PagingViewServiceUpdater:…"`) [inferred] | |

**Page → ink file** [verified, 31/31]: `noteId = UUID(pageId as 128-bit int + 1)`.
**Page order** [verified]: sort pages by the type-54 `4.1` key (byte order).

## 4. `notes/<noteId>` — elements
Pairs of messages: **header** `{1: elemId, 2: clock, 3?: flag, 4?: attachmentId, 8: replica, 9: seq, 14: 5381, 16: 24}`
then **body** `{<KIND>: {...}}`.

| Kind | Count | Meaning |
|---|---|---|
| 7 | 6030 | **Stroke** [verified] |
| 1 | 42 | **Image** [verified] |
| 21 | 4 | **Text box** [verified] |
| 20 | 1 | **Sticky note** [verified] |
| 22 | 10 | **Line shape** (dashed connector) [verified by render] |

### Stroke body (kind 7)
| Field | Meaning |
|---|---|
| 1 | element id |
| 2 | `bv41` blob → **tpl payload** (below) |
| 4 | color `{1:r, 2:g, 3:b, 4:a}` f32 0–1; **omitted component = 0** (`{4:1}` = black) [verified] |
| 6 | translation `{1:dx, 2:dy}` (after lasso move) [verified by render] |
| 3 = 4 | variable-width pen variant (269 strokes) [inferred] |
| 9 | `{15: f32}` extra pen param, e.g. size in pt [unknown] |

### `tpl` payload [verified: all 6,030 parse with 0 leftover bytes]
`"tpl\0" u32 totalSize <ASCII signature>\0 <values…>` — little-endian, self-describing:
`v` = u16, `u` = 32-bit word (here f32 bits), `f` = f32, `A(x)` = u32 count + items, `S(…)` = struct.

Main signature `vuA(v)A(S(uu))A(S(uuuu))vA(f)` (5,760 strokes):
| # | Type | Meaning |
|---|---|---|
| 0 | v | version (2) |
| 1 | u | **stroke width** (f32) |
| 2 | A(v) | commands: `0` = moveTo, `1` = quadratic segment |
| 3 | A(S(uu)) | moveTo points (x, y) |
| 4 | A(S(uuuu)) | segments (ctrlX, ctrlY, endX, endY) → SVG `Q` [verified by render] |
| 5 | v | flag [unknown] |
| 6 | A(f) | per-point extra (pressure?) — empty in sample [unknown] |

Second signature `[v|vu]A(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)` (270) has three observed shapes:
- **All arrays empty** (255; header kind 4): no geometry in the record — nothing to draw [verified].
- **Flat path** (commands only 0/1): value `base` = commands, `base+1` = flat `(x, y)` moveTo list,
  `base+2` = flat `(cx, cy, x, y)` quadratic segments — same path model as above, multiple subpaths [verified].
- **Variable width** (fountain pen; commands 2/3 or 4/5): the record stores the **filled outline**.
  `base+4` = outline codes, `base+5` = flat `(x, y)` moveTo points, `base+7` = flat cubic Bézier
  coordinates `(c1x, c1y, c2x, c2y, x, y)`. Two code tables are observed [verified, 14/14 strokes]:
  A: `2` = moveTo, `4` = cubic; B: `0` = moveTo, `2` = cubic, `6` = close. A table applies only when
  `count(move) × 2 = len(starts)` and `count(cubic) × 6 = len(cubics)`. Fill rule: nonzero.
  `base+1..3` (keypoints with width, centerline) are not needed for rendering.

### Image body (kind 1) [verified by render]
`4` = attachment id (`attachments/<id>`), `3` = frame `{1:{x,y}, 2:{w,h}}`, `2` = second rect (crop/original?) [inferred].

### Text box body (kind 21) [verified]
`20.1` origin, `32.2` size, `32.5.1.30` font (`"Helvetica Neue"`), `32.5.1.40` size (24),
`32.1.2` = `bv41` blob → protobuf `{1: {1: text, 2: run style (font name at 30), 3: paragraph style}}`.
A run without field 1 is an **empty text box** (3 of 4 in the sample).

### Sticky note (kind 20) [verified]
`20.1` origin, `21.2` size, `30` background RGBA, `31` content (same `{1: {2: bv41}}` run format as
text boxes; the sample's note is empty), `32` note id, `33` author name, `40: 1`.

### Line shape (kind 22) [verified by render]
Geometry is either `20 = {1: {1: start}, 2: via point (repeated), 3: {1: end}}` or
`21 = {1: {1: start}, 3: {1: end}, 5: {2: midpoint}}` (a midpoint on the chord ⇒ straight line).
Style `32 = {1: width, 2: {2: {1: dash on, 2: dash off}}, 3: {1: RGBA}}`; `31: 2` unknown.
Dash lengths are imported as multiples of the width [inferred].

## 5. `search/<noteId>` — handwriting recognition [verified]
Message `{5: id, 6: word…}`; each word: `1` bbox `{origin, size}`, `3` ranked candidates (strings),
`4` packed f32 confidences, `7` source strokes with sampled points.

## Implementation
`Sources/InkbookCore/Import/Goodnotes/` — `ProtoReader` (wire format), `AppleLZ4`, `TPLDecoder`,
`GoodnotesImporter` (mapping + `ImportReport`). Against the 31-page sample every element imports:
6,030/6,030 stroke records (5,761 centerline strokes, 14 exact fountain-pen outlines, 255 empty),
42 images, 1 text box (+3 empty), 10 line shapes, 1 sticky note; `unsupported` is empty.

## Known gaps
1. PDF page index for backgrounds (`template.6`) inferred from one sample.
2. Kind 22 `31` field and dash units inferred; header `3 = 1` flag (507 strokes) unknown — both render correctly.
3. One sample only: confirm with a minimal-diff set (blank page / 1 stroke / 1 color / 1 text box).
