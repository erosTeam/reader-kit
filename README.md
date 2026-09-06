# Reader Kit (experimental)

Shared HarmonyOS reader integration for NextE, NextN and Koma.

This experimental integration is opt-in and does not replace any application's reader.
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

The surface supports explicit previous/next display item, single/physical-half/
joined-spread rendering, LTR/RTL, original/thumbnail, retry, and host-provided
adjacent units, plus native horizontal swipe paging, double-tap/pinch zoom and zoomed pan.
It also has an optional native continuous List with original-local visible-position reporting.
Continuous zoom, settings, progress persistence, and the production toolbar remain pending.
Koma D1 accepts existing local/downloaded pages only, and does not yet derive
thumbnails. All adapters honestly declare consumer-only cancellation: stale
results are detached/released, but existing transfers are not physically aborted.

## Display mapping and anchors (D2)

`ReaderDisplayMap` is an additive, platform-free API. D3 renders its selected
single/split/spread items or its continuous whole-original rows. It builds one reading unit at a
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

For the original D2 single-image contain lab, all hosts supply destination visibility AND
ability foreground state. The image additionally requires decode completion and
full ancestor-clipped visibility before reporting its top-center anchor. This is
not a general zoom/scroll visibility algorithm or a sibling/system-occlusion
detector. Future viewports must supply their actual observed point; reaching a
final image is not chapter completion.

The 2026-09-06 D2 candidates were built and inspected on NextN/NextE device-237
and Koma device-197: original observation, page changes, background/resume and
return to the production host. NH independent thumbnails and EH sprite regions
remain separate assets. Koma's existing downloaded-page path passed; its new
zero-page catalog/manifest fallback has host behavior coverage only because the
current device data has no qualifying existing chapter. No full-reader parity,
spread/split rendering or adjacent-local-chapter success is claimed.

## Selected-item viewport (D3)

`ReaderPagedSession` owns the map, selected original/physical fragment, and
`ReaderSession` resource slots. Selected-only callers use at most two slots;
the optional neighbor window below uses at most six. It opens each host unit once,
reads only the requested window's metadata, and reuses the same original asset between physical
halves and compatible policy changes. Failed siblings retry independently.
Changing a layout is not a second host-side progress calculation.

`ReaderPagedViewport` renders only that selection. Its neutral events carry
selection, slot, asset and fragment identity; the diagnostic controls live in
`ReaderLabSurface`, outside the viewport. Native original dimensions refine the
map while preserving the anchor. Independent NH previews and EH sprite crops
keep their own thumbnail geometry, even when an original half is selected.
Stable native keys retain resource identity, while cells read the current
reactive snapshot for decode state and dimensions.

`observedAnchor` is separate from the commanded `anchor`. Only an active,
decoded and fully visible selected original may publish it. A spread sibling
finishing first cannot steal the selected page. Retired selection/asset/fragment
callbacks cannot fail or observe a replacement. No core/UI code persists this
fact or turns a final page into chapter completion.

Device237 is the primary fallback for all hosts;197 is supplementary, not a
required acceptance device. D3 N/E237 evidence covers original/thumbnail,
single/spread/RTL/half restoration and foreground return. Koma237 currently has
an empty real shelf: only default-entry, missing-catalog/Retry and Back boundaries
are covered there. Do not call empty-library testing actual reading acceptance.
The first empty display counter `1 / 0` was rejected and corrected to `0 / 0`.
Full-reader parity, complete continuous gesture handling, transition chrome and migration
remain open. Exact candidate/device limits are recorded in NextN's
`docs/plans/active/shared-reader-architecture.md` and project-owned manifests.

## Continuous viewport (D3)

`ReaderContinuousSurface` owns the native List and reuses the existing image/sprite renderer.
Each original uses its full-width intrinsic height; the List, not a fixed-height image cell,
clips the viewport. Metadata survives asset eviction without retaining its image lease.
Independent NH previews use their own dimensions; EH sprite regions use their explicit crop.
The entire sprite canvas uses decoded pixel dimensions at one uniform scale; parsed occupied
extents are only a pre-decode fallback, not a replacement for any padded canvas dimension.
The core session keeps only the actual visible range plus immediate neighbors when enabled.

The visible range drives demand but does not establish a reading observation. Only the first
visible original decoded by the current native cell may publish its measured top-center point.
ListScroller item bounds provide the local normalized coordinate; total scroll estimates and
prefetch completion cannot advance it. Topology/navigation/slot/request fences reject old
callbacks. Explicit page, asset and mode commands restore the anchor through the same core owner.
All of this remains transient: host chapter completion and persistence are not reader facts.

The first continuous slice has 58 actual core behavior tests and signed N/E consumers. NextN237
checks include a 16025px original top/middle/tail, the real adjacent-page seam, NH thumbnail ratio,
mode/asset restoration, rapid explicit navigation and Home/resume. These are bounded endpoint
checks, not animation/performance, rotation, late-dimension restoration or continuous-zoom proof.
NextE237 adds neighboring originals and local-anchor restoration. Its first sprite candidate
was rejected: a 4000x300 canvas was compressed to parsed4000x284. The corrected shared sprite
leaf is inspected in both continuous and paged viewports with the same200x122 crop.
Koma's previous selected-item evidence does not accept its current continuous viewport.

### Continuous page failure and retry

Each failed continuous row owns a compact `ReaderFailurePanel`, instead of relying on a
selected-page-only button outside the viewport. The native row uses the reference220vp
minimum on failure; healthy image ratios are unchanged. Failure and loading/image branches
are exclusive. The shared material preserves the reference196vp compact card and120x40vp
text action; catalog-level failure remains separate. Paged per-pane failure UI is still pending.

`retryItem` takes topology, item, slot and the current request epoch, including acquisition
failures whose assetRequestId is still0. It retries only a visible failed asset without
selecting it, reloading healthy siblings or reopening a chapter.61 actual core tests cover
retry isolation, stale/duplicate/inactive requests and independent spread-pane commands.

N/E debug Want `readerLabFailPage` accepts a zero-based original index and injects one
explicitly labeled render failure after native decode in Continuous. It is scoped to that
Lab request; ordinary entries and release builds do not enable it. The probe does not corrupt
caches or downloads. The user's Retry then uses the real provider's forceReload path.
This exercises failure UI and retry routing, not natural network-timeout handling or quota
classification. Koma does not yet forward the probe parameter.

### Delayed original dimensions diagnostic

N/E debug Want `readerLabDelayMetricsPage` holds only the selected zero-based original's
native size notification; it still acknowledges successful native decode and never clears
authoritative catalog dimensions. The labeled release action forwards the exact held slot/
asset request and keeps its own layout mounted, so test chrome cannot move the viewport.
The probe is absent from ordinary/release entries and does not alter List behavior or caches.

62 actual core tests include previous-row metadata refinement without changing the current
original anchor. On237, E's delayed P1 1280x782 dimensions refined its row from fallback to
762px while P2 stayed at the exact same native rectangle and normalized point0.11650, also
after Home/resume. N's already-known720x9245 original stayed16025px high at point0.06705
before/after release and Home/resume. No List correction was needed for these endpoints.
This is a controlled callback-order test, not all late-size/rotation/gesture timing coverage.

## Selected-item zoom and pan (D3)

`ReaderViewportTransform` is pure fitted-content/focal-point math. The ArkUI
viewport owns transient gesture/animation state; neither layer owns application
navigation, chapters, persisted progress or preferences. All spread parts share
one transform on the joined content Row, with pan bounds derived from the fitted
content rather than a viewport-sized placeholder around each part.

Double tap follows 2x/native/reset (skipping an identical native stop); pinch uses
a dynamic 4–12x maximum and elastic 0.8 minimum settling back to 1x. Pan is active
only after zoom. A new page, physical half, asset kind or display policy resets
the transform; same-resource phase updates and background/resume retain it.
Gesture availability requires the active selected item's assets to be displayed.
The previous whole-original observation is suppressed during zoom/animation:
zoomed normalized-anchor reporting remains unimplemented, not fabricated from
decode completion or transformed bounds.

Current NextN 237 evidence includes native double tap, long-strip top/bottom pan,
explicit two-pointer pinch out/in, asset/page reset and background/resume.
NextE 237 adds a joined 2x frame, both horizontal bounds, layout/half reset and
off-center focal zoom; its current foreground and full screenshots were checked.
These zoom-only terminal checks did not accept gesture arbitration with a pager,
pinch-to-remaining-finger chaining, rotation, animation frames or all three hosts.
The same UI implementation is consumed by all hosts; build consumption is not
host-specific physical gesture acceptance. Exact NextE and Koma limits remain
in the project acceptance record.

## Native horizontal pager (D3, experimental)

`ReaderPagerSurface` adds a nonlooping native `Swiper`/`LazyForEach` parent around
the existing fitted viewport. Diagnostic chrome and host navigation stay outside.
`ReaderPagedSession` is still the only display-map/anchor owner: an opt-in window
contains the previous, current and next display items, at most six unique original
assets for spreads. A physical half can share the same asset slot with its neighbor.
Prefetch/decode cannot publish a selected reading position or chapter completion.

Render keys are scoped to a topology revision, not persisted as page identities.
Native index feedback carries both topology and navigation revisions; delayed
callbacks from an old map or superseded command are rejected. Feedback is deferred
out of native `onChange` to avoid recursive `LazyForEach` updates. Cached item
snapshots are detached render projections, not independent reading sessions.

Only the active selected item can lock paging for pinch, zoom animation or zoomed
pan. Motion suspends visibility reporting, background suspends gestures, and a
cached outgoing item resets its transform when it ceases to be selected. Same
selected-image background/resume retains the settled transform. Asset failures
are fenced to their actual cached item; Retry concerns only the selected item.

NextN237 currently covers LTR/RTL single and spread swipe roundtrips, a new
single-finger pan after explicit pinch, pinch reset restoring swipe, and
background/resume retaining zoom lock. NextE237 covers the whole-image baseline,
physical-half LTR/RTL roundtrips, RTL joined-spread roundtrip and zoomed
background/resume retaining the first joined pair during a new horizontal pan.
Exact current results and limits are in the app ledger.
The first recording is downscaled and has local ghosting, so it is retained as
qualitative sequence evidence, not clean-motion or pixel-geometry acceptance.
Pinch-to-remaining-finger continuity, rotation, concurrent topology change during
drag, Koma pager behavior and all later migration work remain unverified.

Run core behavioral tests with `node --test tests/*.test.cjs`.
They execute the actual platform-free ArkTS core through the DevEco TypeScript
compiler. Set `READER_KIT_TYPESCRIPT` if that compiler is installed elsewhere.
Host tests do not substitute for the three apps' device acceptance.
