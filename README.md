# Reader Kit (experimental)

Shared HarmonyOS reader integration for NextE, NextN and Koma.

This D1 integration is opt-in and does not replace any application's reader.
`reader-core` owns neutral catalog/session contracts; `reader-ui` contains the
shared diagnostic surface. Host adapters resolve their own sources and files.
The diagnostic session does not save reading progress or preferences.

The current prototype is not a complete reader. Production routes continue to
use their existing implementations. No remote repository or package publication
is configured by this prototype.

## Local development

Keep `reader-kit`, `NextE`, `NextN`, and `Koma` as sibling directories. The app
module registrations and local OHPM dependencies refer to this single source
directory. Run the app's normal `ohpm install --all` and signed Debug build;
build consumers sequentially because source HAR build outputs are shared.
Remote distribution and CI checkout wiring are not configured in D1: do not
publish these app integration patches as a standalone production release.

The Debug-only lab accepts explicit Want parameters `readerLabWork`, optional
`readerLabUnit`, and zero-based `readerLabPage`. E uses the gallery token as its
unit argument at the host boundary; it is not a core identity field. N needs
only its gallery id. Koma needs a real library comic id and optionally chapter
id. Ordinary launch/deep links and Reader destinations are unchanged.

The surface currently supports explicit previous/next page, original/thumbnail,
retry, and host-provided adjacent units. It has no zoom/pan, continuous mode,
spread layout, settings, progress persistence, or production toolbar yet.
Koma D1 accepts existing local/downloaded pages only, and does not yet derive
thumbnails. All adapters honestly declare consumer-only cancellation: stale
results are detached/released, but existing transfers are not physically aborted.

## Display mapping and anchors (D2)

`ReaderDisplayMap` is an additive, platform-free API; the diagnostic UI does not
yet render its spread/split/continuous items. It builds one reading unit at a
time from its known page count and a possibly sparse set of `ReaderPage` metadata.
It never downloads images or reads preferences. Unknown original dimensions do
not fall back to thumbnail dimensions.

- `single` may expand a wide original into left/right page turns (Koma's 1.2
  ratio by default); `spread` and `continuous` keep whole originals.
- `spread` pairs adjacent source pages, with an optional first-page-alone rule
  matching E/N's existing cover alignment. It never pairs across units.
- Items and parts stay in logical order. `visualParts('rtl')` reverses a spread's
  presentation only; `neighbor()` is logical navigation, not a Swiper index.
- `anchorAt()` maps a UI-observed part-local point into original-page normalized
  coordinates. `resolve()` preserves source identity and the physical half across
  layout, direction and metadata changes. Its result is a navigation target,
  **not** proof of visibility, progress saved, or chapter completion.
- A stable page key missing from a sparse map yields `pending-metadata`; missing
  from a complete map yields `missing-page`. Index fallback requires an explicit
  opt-in and is reported as `index-fallback`. A different unit/account never
  falls back. Null keys are temporary index hints, not persistent identities.
- Copy boundaries protect inputs and returned items/anchors. A caller rebuilding
  the map keeps the old anchor until resolution succeeds, then carries the
  returned anchor forward (including its resolved half).

The current API requires a known finite page count; open-ended catalogs, content
revision handling and host persistence remain subsequent integration work.
Page-key stability belongs to the host.

## Observed position and resource identity (D2)

`ReaderSnapshot.requestId` identifies the newest command; `assetRequestId`
identifies the retained image. They deliberately differ while the next unit is
only being prepared. Native image keys and callbacks use the asset identity so
an old image cannot confirm a newer request.

Decode completion changes the diagnostic `phase` to `displayed`, but does **not**
publish a reading position. The separate `presentedAnchor` / `presentedRequestId`
pair records only a matching, decoded original reported by an active viewport.
Navigation, thumbnails and failures retain the last observed original, including
its old unit identity during a chapter transition. Observations are copied,
validated and deduplicated; no settings/progress/tracker writes occur.

For this single-image contain lab, all hosts supply destination visibility AND
ability foreground state. The image additionally requires decode completion and
full ancestor-clipped visibility before reporting its top-center anchor. This is
not a general zoom/scroll visibility algorithm or a sibling/system-occlusion
detector. Future viewports must supply their actual observed point; reaching a
final image is not chapter completion.

The 2026-09-06 final candidates were built and inspected on NextN/NextE device-237
and Koma device-197: original observation, page changes, background/resume and
return to the production host. NH independent thumbnails and EH sprite regions
remain separate assets. Koma's existing downloaded-page path passed; its new
zero-page catalog/manifest fallback has host behavior coverage only because the
current device data has no qualifying existing chapter. No full-reader parity,
spread/split rendering or adjacent-local-chapter success is claimed.

Run core behavioral tests with `node --test tests/*.test.cjs`.
They execute the actual platform-free ArkTS core through the DevEco TypeScript
compiler. Set `READER_KIT_TYPESCRIPT` if that compiler is installed elsewhere.
Host tests do not substitute for the three apps' device acceptance.
