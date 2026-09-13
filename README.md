# Reader Kit (experimental)

## Optional host-owned preference output (2026-09-13)

`ReaderSurface.onPolicyChanged` and `onCropChanged` publish only the runtime
state that the shared session actually adopted. The core and shared UI do not
know an application's preference schema and never write application storage.
Policy and crop output are separate from observed reading progress, so hosts
can grant, map, test and migrate those capabilities independently.

Koma's Debug Lab keeps preference writes disabled for ordinary requests. An
explicit full-reader `readerLabPreferencesReadWrite=true` request maps the
shared layout, paging axis, direction, spread layout, cover alignment, wide-page
split and border crop into Koma's existing preference store while preserving
all unrelated Koma fields. On device103, ordinary runtime changes left the
preference file byte-identical; explicit changes persisted vertical paging and
crop, survived force-stop/relaunch, and were then restored to the complete
pre-test preference value set. Production reader routing remains unchanged.

## Optional host-owned observed progress (2026-09-13)

`ReaderPagedSnapshot.observedPosition()` reports only decoded original parts that
the native viewport actually displays. It excludes thumbnail previews and
continuous-list prefetch neighbors, keeps the stable source anchor, and reports
whether the terminal source page is among the visible originals. The core and
UI never choose a persistence format or write application data.

`ReaderSurface.onObservedPosition` is an optional host callback. Koma's Debug
Lab keeps it disabled by default; an explicit full-reader
`readerLabProgressReadWrite=true` request maps it into Koma's existing
`ReaderSessionStore`. A finite `readerLabPage` remains an explicit test
override, while an omitted page restores the existing chapter position.

On device103, the controlled two-page test chapter reached `2 / 2` with its
progress file byte-identical in ordinary Lab mode. With explicit read/write
permission it persisted zero-based page 1 as completed, then a force-stop and
launch without a page override restored `2 / 2`. This accepts that optional
Koma path only; production reader routing remains unchanged.

## Optional host-owned chapter handoff (2026-09-12)

The full reading surface now accepts optional chapter-navigation capability,
busy state and source-unit-bound intentions. Existing snapshot adjacency flags
control the previous/next entries in More; hosts without this capability keep
their current menu. Chapter navigation does not depend on a decoded information
frame, so a failed body image does not trap a chapter-capable reader.

Koma prepares its existing local catalog before opening the target unit. A failed
preparation does not change the live session; close/background invalidates the
pending host request. No production chapter hydration or preference writes are
introduced, and ordinary Lab requests remain progress-read-only. The auxiliary rail is keyed by scope/work/unit and
page count; ordinary same-unit navigation keeps its existing instance.

Device197 observed downloaded 11-page to 19-page switching with the rail open,
last-page selection in both units, and return from a catalog-ready 55-page unit
whose local body images are unavailable. This last case is asset failure, not
catalog preparation failure. Preparation-failure retention and in-flight cancel
races are source-reviewed only. Device103 (MLR-AL00) normally imported a controlled
five-page CBZ and retained page 2 and its rail selection through portrait to
landscape to portrait. Its normal folder import failed, so tablet cross-chapter
navigation is not accepted. Both trials left progress unchanged; the new test
comic was explicitly authorized and remains available. The shared reader remains
optional and is not ready for default replacement.

Shared HarmonyOS reader integration for NextE, NextN and Koma.

This experimental integration is opt-in and does not replace any application's reader.
`reader-core` owns neutral catalog/session contracts; `reader-ui` contains the
shared diagnostic surface and an optional full-window reading surface. Host adapters resolve their own sources and files.
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
Continuous images also support per-image zoom with List-scroll arbitration. Settings
persistence, production route migration, and complete production toolbar capabilities remain pending.
Settled continuous zoom now preserves content-relative translation through measured
width reflow while the List restores its unscaled anchor behind the native frame gate.
NextN long-original and NextE original/sprite portrait-landscape-portrait endpoints
were inspected on device237, including new pan and NextN pinch-reset/continued scroll.
These bounded observations do not accept the diagnostic split-window layout as
production chrome, all intermediate frames, every pan clamp, or Koma runtime.
Koma D1 accepts existing local/downloaded pages only, and does not yet derive
thumbnails. All adapters honestly declare consumer-only cancellation: stale
results are detached/released, but existing transfers are not physically aborted.

## Optional reading chrome (D4 first slice)

NextN/NextE Debug hosts accept `readerLabChrome=true` on the explicit Lab Want.
This adds a full-window trial route without replacing ordinary readers or the original Lab.
`ReaderSurface` composes the existing paged/continuous viewports and their resource callbacks;
`ReaderChrome` owns only presentation/slider preview and emits close, policy and source-seek intents.
The host owns routing, safe insets and the optional `ReaderTrialWindow` color lease, which restores
the captured pre-trial system-bar properties. Neither surface nor core writes application preferences.

The first controls are chrome show/hide, outlined passive page status, source-page seek,
single/spread/continuous, LTR/RTL, cover alignment and physical wide-page splitting.
Source seek uses a captured unit/navigation token, never a display-item index or a saved observation;
re-seeking the same source intentionally resets its viewport to the start.
Single/double recognition is exclusive within the existing pinch/pan group. A fresh one-pointer
sequence is required after pinch/pan, so the previous gesture's tail cannot open the toolbar.

72 core tests and two named native tests per N/E host ran on237. Inspected evidence includes
same-source zoom reset, actual LTR/RTL page changes, outlined status on light/dark backgrounds,
pinch-tail suppression and close restoration. The E P117/P118 full-window comparison preserves
the reference image rectangle, progress row and trailing layout group. This is not full parity:
thumbnail rail, share/save/original-source actions, auto reading, full settings/system input,
transition integration and Koma trial chrome remain subsequent slices. Slider mid-drag preview,
retry/tap interaction and remaining lifecycle combinations still need their own native acceptance.

## Auxiliary thumbnail navigation (D5)

The optional reading surface now adds the reference overlay rail above its fixed bottom toolbar.
Its native horizontal List uses source indexes and RTL direction; only selecting a tile seeks the reader.
`ReaderThumbnailWindow` owns visible-range-plus-one-neighbor preview leases over the already prepared
catalog. It never reopens a unit, selects a reading page, or reports original visibility. Retired requests
release late assets; retry targets one exact failed slot. NH dimensions come from the preview itself;
EH retains the sprite cell crop and uniform sheet pixel scale. Unsupported previews do not load originals.

79 core tests pass. N/E237 named native suites each pass one sequence with all eight whole captures/root
states inspected: opening leaves the main image fixed, later thumbnails load without changing the page,
selection changes the original, RTL/hide/reopen retain it, and close restores the host. Independent N
spread selection displays/highlights both original pages; E P117/P118 matches the production rail and
image rectangles. No default reader, preferences or saved progress changed. Slider-preview following,
thumbnail failure interaction, background/rotation while browsing and Koma derivation remain unaccepted.

## Transient source seek (D6)

Slider Begin/Moving publishes a unit/navigation-scoped UI preview. It positions the
auxiliary rail directly without navigating the original or publishing reading progress.
End/Click commits only a still-current capture; cancellation, inactive/unmounted chrome
and changed navigation discard it. The native List owns its visible resource range, so
release does not retire already visible neighboring thumbnails before the List reports.

Device237 N/E candidate3 native interruption suites each pass one real background/resume
and RTL-release sequence, with all five whole screenshots and roots inspected per host.
N's271-frame recording follows preview1→9 while original1 stays fixed until release;
visible thumbnails remain loaded. E's288-frame sustained long-list recording follows
preview117→396 while original117 stays fixed until release; unknown previews may still
load. The earlier animated candidate did not follow during E's sustained gesture.
79 core regressions pass; these are bounded native observations, not complete parity.
Rotation/unit replacement during an active drag, thumbnail failure/tap arbitration,
Koma trial chrome and production host capabilities remain open. Defaults and persistence
are unchanged. Earlier slice limitations above are chronological, superseded only by
these explicitly observed paths.

## Thumbnail recovery arbitration (D7)

An explicit Debug-only `readerLabFailThumbnailPage` zero-based Want parameter now
selects one thumbnail for a one-shot missing local URI. `ReaderLabAssetProbe`
exercises the native decoder failure callback; retry delegates to the real host
provider. It neither deletes cache files nor simulates a transport outage.

N/E237 native tests wait for the thumbnail session's native-decoded `displayed`
phase, not merely an Image node. Both final tests pass with five whole captures
and native roots inspected per host: the failed second thumbnail recovers without
seeking the first original, losing healthy previews or hiding chrome; a fresh tile
selection then displays the second original, and close restores the ordinary host.
An earlier E capture preceded its healthy sprite decode and is retained as rejected
readiness evidence. No additional gesture interception or visible layout change
was warranted.79 core tests pass. Remaining host inputs/actions and lifecycle
combinations are still separate replacement-readiness work.

## Host input boundary (D8)

`ReaderInputPort` delivers synchronous logical previous/next intents to the current
surface connection. It has no platform key codes or queued commands; a retired
connection cannot detach a new owner. `ReaderSurface` arbitrates native viewport
locks, active state, touch, menu and seek preview before forwarding to its session.
`ReaderVolumeKeys` is an optional platform lease instantiated by the host route.
It registers distinct callbacks and removes each exact callback on hide/background/close.
N/E Debug hosts enable it only with explicit `readerLabChrome=true` and
`readerLabVolumeKeys=true`; no existing preference or default reader is changed.

81 core tests pass. N/E237 each pass the named native paging/menu/zoom/background/
pinch-reset/continuous/close sequence with all nine whole captures and roots inspected.
Separate release tests show unchanged system volume while reading and an actual system
media-volume panel after close; the one-step change is restored to the read baseline4.
Three whole captures per host verify ordinary-host and system-panel ownership.
The earlier double-tap-reset test assumption was rejected: the real cycle includes
native scale. Active-drag/seek/rotation key combinations, platform registration failure
injection and Koma input runtime remain unaccepted. These bounded results are not
complete replacement readiness.

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

### Continuous per-image zoom and scroll arbitration

`ReaderContinuousZoomImage` reuses the shared focal-point transform and native asset/sprite
renderer. Only the image transforms; the parent List retains its intrinsic row geometry,
raises the current zoom owner, and disables native scroll input while that image is pinching,
animating or zoomed. A navigation/slot/asset epoch owns the lock. Settled zoom survives Home;
explicit navigation, asset replacement, failure and width reflow release/reset it.

The gesture region includes the transformed image, including its visible overlap outside
the original row. The first candidate displayed that overlap but could not drag there;
the exact device237 failure and corrected replay are retained in the consumer ledger.
Failure/loading controls remain outside the transform. Unscaled List-position observations
pause during zoom and resume after reset; zoomed original coordinates are not fabricated.
Programmatic List positioning stays pending until a native frame finishes, preventing an
old row rectangle from being reported as the new command's position. Navigation, width and
disposal invalidate queued frame callbacks; the core remains the sole reading-fact owner.

66 actual behavior tests include long-row focal math and minimum-row insets. The N/E237
protocols separately check real two-pointer gestures, overlap hit testing, Home, reset,
asset replacement and command timing. These endpoints do not cover remaining-finger
continuation, rotation, all late-size/zoom combinations or Koma runtime.

### Continuous page failure and retry

Each failed continuous row owns a compact `ReaderFailurePanel`, instead of relying on a
selected-page-only button outside the viewport. The native row uses the reference220vp
minimum on failure; healthy image ratios are unchanged. Failure and loading/image branches
are exclusive. The shared material preserves the reference196vp compact card and120x40vp
text action; catalog-level failure remains separate. Paged recovery is described below.

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

### Paged per-pane failure and retry

Paged cells use the same failure panel and exact `retryItem` event path. An error is
laid out in the full single viewport or equal independent spread panes, not inside
a long original's narrow fitted width or a landscape spread's short image frame.
Healthy sibling images remain contained at their own aspect ratio. Recovery geometry
persists while retries load; all displayed panes restore the normal joined frame.
Healthy keyed native image subtrees and asset requests are retained during a sibling
retry. Failure resets image zoom and leaves paging available; cards cannot be zoomed.

`readerLabFailureLayout=single|spread` extends the explicit N/E failure probe; omitted
or invalid values retain its existing Continuous-only default.64 actual core tests
include physical-half retry identity and a healthy selected spread sibling. Current
device acceptance is recorded by the consuming app, not inferred from shared source.

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

## Asset-bound image information (D10)

Hosts may attach a read-only `ReaderImageInformationSource` to a retained
`ReaderAsset`. Core exposes it only for a currently displayed original and fences
the result by slot, request, unit, navigation and foreground generation. It never
derives file dimensions or format from catalog/thumbnail metadata, and metadata
failure does not fail the displayed image. The optional platform file adapter
reads ImageSource headers without fetching or decoding another full image.

The shared chrome uses a native more-menu and visual left/right source choices
for spreads, then a system information dialog. Preparation indication ends when
the dialog appears; modal input remains locked until dismissal. The composed
HAR strings use host resource names, not numeric IDs from a different main/test
package. Unsupported hosts keep the capability absent.

92 core tests cover actual file facts, error recovery, stale requests, LTR/RTL
source identity and delayed results after navigation/background/close. The N/E
native ordinary path is single information, both spread sources, dismissal,
fresh page movement and route close; its current results and screenshots live in
NextN's D10 acceptance ledger. Native metadata failure/delay probes, continuous
and physical-half combinations, Koma metadata and full replacement remain open.
No production reader, settings or progress migration is enabled.

## Optional asset-scoped border crop (D11)

Hosts may attach a `ReaderImageCropSource` to a retained body asset. Detection stays
in the host: NH and EH do not share their background-detection algorithm. The core
fences results by asset/request identity and keeps crop metadata for the reading
unit even after an image slot is evicted. It never rewrites source dimensions or
image files. Physical halves retain the original split boundary; continuous pages
retain side crop while top/bottom crop applies only at the unit's outer edges.

`ReaderSurface.cropBorders` selects initial runtime state. `cropAvailable` separately
enables the existing menu's on/off intention, whose state comes from the session
snapshot. Both default to false. N/E standalone trial hosts expose the control;
thumbnail-entry and Koma currently do not. No preference or progress is migrated.

Device237 N/E single, spread and continuous off/on/off endpoints were inspected,
including same-page retention, proportional body crop and restored continuous row
height. E's zoomed P5 matched its production reader's body position/size and crop
shift; N's zoomed P3 retained enlargement and visually restored its comic panels.
UiTest clips Image bounds to the viewport, so equal returned bounds are not an
exact original-point oracle. High magnification, continuous zoom plus crop, motion,
thumbnail transitions and Koma crop remain unaccepted. Detailed reports and actual
screenshots are in NextN protocols244–254 and its active acceptance ledger.

## Host-owned page actions and processed variants

`ReaderSurface` can render host-supplied `ReaderHostAction` rows in its existing
overflow menu. Invocations carry the exact unit, navigation revision and canonical
source index captured when the menu opened; the host still owns the action's
service, account, cache, persistence and confirmation UI. Optional passive host
status text is overlay-only and never changes the reading viewport.

Hosts that need different processed-image choices per page may provide a
`variantPreferenceResolver` plus an explicit revision. Core still accepts only an
exact `ReaderVariantPreference`, resolves it through `ReaderAssetProvider`, and
fences late preparation on navigation, background and close. Completion is
reported back to the host without teaching reader-kit what an app-specific
translation or enhancement workflow means. The original global preferred-variant
parameters remain available for simpler hosts.

## Optional adjacent-unit boundary intent (D12)

Paged and continuous surfaces can emit the existing host-neutral `onChapter`
intent after one explicit swipe begins at a real unit boundary. Native `Swiper`
and `List` retain gesture ownership: the shared layer adds no competing Pan, does
not use `List.onReachEnd`, and never opens a chapter itself. Direction is mapped
through horizontal LTR/RTL or vertical paging, then fenced by the captured
topology and navigation revisions and the current adjacent-unit availability.

Koma197's optional shared-reader lab accepted paged and continuous forward and
reverse boundaries against two real neighboring chapters. The continuous forward
case first scrolled the final image to the actual List end and switched only on
the following upward swipe. Each accepted boundary produced one intent, opened
the adjacent chapter at its first page, kept the reader chrome intact, and left
the production library and progress files byte-identical. This is host handoff
evidence for the optional lab, not production-reader replacement or persistence
acceptance. A bounded debug-only chapter probe also proves that preparation
failure and background cancellation retain the source chapter and emit no opened
target; ordinary requests cannot enable it. The complete platform-free suite now
has 317 passing tests.

Run core behavioral tests with `node --test tests/*.test.cjs`.
They execute the actual platform-free ArkTS core through the DevEco TypeScript
compiler. Set `READER_KIT_TYPESCRIPT` if that compiler is installed elsewhere.
Host tests do not substitute for the three apps' device acceptance.
