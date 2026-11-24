# Reader Kit

Shared HarmonyOS reader integration for NextN, NextE and Koma. Ordinary Shared
routing and retained Legacy fallback belong to each host, not to this package.
Koma ordinary opens now honor its saved reader implementation preference; its
Shared route and retained Legacy fallback remain host-owned. A common package revision does not establish
host reachability, full replacement, all-provider coverage or performance.
Runtime acceptance belongs to the active host work order and its bound receipts.

## Consumer contract

This is the common ownership boundary for all three consumers. Host agent
guides add their own data, product and device rules; they must not substitute
three different lifecycle implementations for a shared invariant.

| Owner | Responsibility |
| --- | --- |
| `reader-core` | Catalog/session identity, display mapping, canonical observed position, request generations and bounded resource demand |
| `reader-ui` | Shared reading surface, paged/continuous presentation, image/gesture arbitration, chrome and thumbnail rail, current loading/failure presentation |
| Host adapters | Source/network/local/archive access, cache/download services, request cancellation capability and source-specific failures |
| Host application | Existing menus/settings semantics, preference/progress persistence, chapter preparation, media/processed-image actions, navigation and system-window ownership |
| Host root transition | Valid source claim, source-to-target thumbnail flight, current return-target measurement and source restoration |


File-backed border decoding, packed RGBA export, content fingerprinting and bounded
crop caching belong to `ReaderFileCropService` in reader-ui; strength-aware pure
detection and source-size bounds belong to reader-core. Hosts provide retained
files/asset identities and their existing strength preference. The host crop model
and service exports are compatibility names only, including retained Legacy paths.

Temporarily hiding an enhanced image keeps its completed recipe within the
current resource window. Restoring that recipe does not restart enhancement.
The native slot can reuse the same page's previously displayed default file
until a reload or an identity change invalidates it. Current preparation
priority follows the selected page as the user navigates.
The original `ReaderFileCropSource` API retains its prior conservative policy;
explicit host strengths retain their existing thresholds and 1-based Legacy seam
semantics. Pixel buffer rows use `width * 4`, never native allocation stride.

Reader HDR brightening is opt-in through `ReaderImageEffects`. Hosts own the
settings and declare `ohos.permission.HDR_BRIGHTNESS`. The selected SDR page
blends to a fixed 1.5× HDR image after it has been displayed. Keep the SDR image
under the native opacity animation until the HDR image is opaque. The same
logical page retains the blend when its processed image replaces the original.
The native original owns loading, geometry, media actions and fallback throughout. See the
[shared HDR image](reader-ui/src/main/ets/ReaderHdrImage.ets).

Before a product edit, recover the existing user behavior independently of the
patch, then trace the changed owner, callers, writers, async callbacks, parent
and sibling state, every applicable consumer, and the retained Legacy route.
Record direct/indirect exposure or a concrete reason for being unaffected.
Source-mapped cause and impact precede implementation. Build/runtime evidence
follows the coherent change; do not adjust behavior through repeated test runs.

In continuous mode a new original's successful presentation and measured
dimensions belong to the same snapshot. The native List consumes them together.
Only visible-position observation advances reading progress. Vertical is the
default continuous axis for existing hosts. Horizontal continuous uses the same
native List and source order, fits page height to the viewport, and lets layout
direction place the leading edge without reversing page indices or chapter order. Its chapter/policy
check can use `displayPolicyForUnit` without rebuilding the render window.
Continuous zoom starts an animation transaction only on double tap. Loading
and direct gesture transforms apply without opening a layout transaction.
Loading feedback is display-only and never owns input. The catalog canvas
routes taps before pages exist; chrome does not wait for a catalog, decoded
image, or page geometry. With a page map, navigation can leave a pending or
failed image; only zoom requires displayed pixels. An explicit navigation
intent cancels a pending entry-geometry wait. Continuous tap arbitration belongs to the row/navigation identity;
an image request becoming ready cannot cancel a pending chrome tap. Entry
positioning gates automatic positioning and zoom, not explicit chrome/navigation.
A catalog failure still exposes reader chrome from its own surface. Retry
stays a separate action, and host settings remain accessible without pages.

The following are existing preservation requirements, not new feature work:

- With a valid thumbnail claim, retain the host root flight. Without it, retain
  the ordinary system entry. Never open fullscreen first and then imitate the
  flight inside Reader, wait for a second thumbnail capture before departure,
  or let a child writer change source system-bar visibility/colors early.
- Motion completion and original-image readiness are different states. Retain
  the current thumbnail/image and its loading backdrop while the same request
  is pending; canceling motion does not mean decode/presentation is complete.
  Loading feedback belongs to current request identity, not a retired callback.
  Real byte counts drive the percentage during transfer. When all bytes have
  arrived, the existing stage label and indeterminate bar describe the wait for
  preparation and decode. The image owner still ends feedback at presentation.
  A low-resolution opening thumbnail is a preview, not a readable original: it
  retains the existing loading indicator/backdrop until this original is ready.
  A matching decode is insufficient while the entry still hides that original.
  Its existing reveal commit exposes the original and retires feedback together.
  When native dimensions are published before a continuous row receives them,
  its matching later metadata must complete the pending decode even if physical
  rounding leaves the row geometry unchanged. Presentation deduplication must
  not strand that native receipt or manufacture a new decode from a URI alone.
  Core may retain a displayed resource across a mode switch; a new native
  viewport still waits for its own matching decode before ending this feedback.
  The retained in-place replacement branch keeps already readable pixels.
  A matching native decode may expose the original before the composed-frame
  receipt. Forward that exact slot/request to core before revealing pixels;
  retain its lease across a fast enhancement handoff without advancing read progress.
  If a cached derivative supersedes an undecoded replacement, keep the last
  actually presented lease and request epoch until the final candidate presents;
  an undecoded candidate must not become the fallback or discard it. This also
  preserves the separate native candidate site when both files have the same URI.
  Before a newly mounted pager reports its real dimensions, that same feedback
  belongs to the full viewport; measured page cells take it over after layout.
  Plain loading bars, tracks and labels use the host loading ink (defaulting to
  its canvas foreground) in both paged and continuous leaves. Feedback over retained entry pixels keeps its
  established dark panel and light ink; canvas colors do not override that panel.
- Toolbar reveal has two required cases: when the current native status-bar
  show operation applies, finish that operation before painting the toolbar;
  when status-bar control is absent or unsupported, keep the toolbar usable.
  The Window setter Promise is only an acceptance receipt, not completion of
  visibility (Huawei Window API). In a same-size main
  window that has actually supplied a status area, the common controller waits
  for its native area signal, then Surface commits after the render boundary.
  Zero/unknown-area and floating windows do not require that signal; unsupported
  reads/listeners and a finite missing-signal failure also leave chrome usable.
  The native write queue must remain free for hide/close while this wait is pending.
  Never gate on the host's `topInset > 0`, cache a height for placement, add a
  success delay, or restore host-specific preparation callbacks.
  Cancellation, another toggle,
  close and background retire a pending reveal. A fix for either case must
  preserve the other; synchronous-commit assertions cannot replace this contract.
- Host chrome appearance preserves its established title, geometry, and control
  order. Restoring one host must leave the shared default appearance unchanged;
  appearance parameters cannot change reading policy or action ownership.
- Enhancement status preserves its host-owned processing/applied/temporary-off
  states and toggle. Idle uses the shallow neutral base; processing/applied use
  a 40%-opaque theme fill with black/white ink selected for contrast. A dark accent
  must not be painted as status ink on a dark translucent background; readability
  must hold across themes and underlying comic colors without changing processing.
- Keep one canonical value for a setting. The row label, menu check, bottom
  control and adopted session behavior must project that value. Shared routing
  must preserve existing button/menu semantics, options and live updates.
- Page selection updates local observed state. Retain the reading session,
  thumbnail rail, scroller and unrelated image nodes; do not key/remount an
  entire page or list by page number to obtain an update. Build the rail for a
  chapter when it is shown. Hiding it within that chapter keeps its decoded
  leases without following pages or demanding new ranges; showing it adopts
  the current position before visible following. A visible tile eases its
  layout width from the placeholder to the bounded thumbnail ratio. The image
  and page label share that width; hidden or retired tiles do not animate.
  Declarative updates
  are required; minimizing their scope does not mean prohibiting all rebuilds.
- Preload demand rolls with navigation, range, policy and unit changes; an
  initial warm window is not continuous preload. Transport warming is not
  decode or visible presentation. Hosts retain their own bounded cache owners.
  With next-unit warming enabled, the last few source pages can prepare the
  following unit's page list before the image budget crosses the boundary.
  A growing next-unit budget keeps its pending preparation alive. Only the
  configured page budget is spent on image warming.
  In continuous reading the native list reserves one viewport of loading space
  for a verified neighbor while its catalog is pending. The row reuses the key
  of the real page at that seam: the predecessor's final page or the successor's
  first page. The current resume page still owns the initial viewport. After
  a gesture settles in a reserved row, the seam survives late image measurements.
  The reserved row never selects a page, leases an asset or updates progress.
  Catalog failures can be retried in place.
  A host resolving legacy chapter chronology beside a readable page can call
  `refreshAdjacency()` to publish the resulting neighbors and resume lookahead;
  this must retain the current anchor, native topology and decoded images.
- Crop on/off reuses ready enhanced/translated recipes. Model/translation
  identity and detector revision still invalidate their prepared results.
- Paged reading projects host-verified neighboring chapters into the same native
  Swiper. Its render index/keys are separate from the selected chapter's local
  display index/count; every frame keeps its real unit/page identity. A boundary
  swipe or tap promotes that prepared chapter without reopening/releasing its
  decoded slots. Native chapter insertion publishes its full count in one
  dataset operation and preserves visible keys; processing/transport
  still follow their own bounded demand and a cached decode cannot write progress.
  A press alone cannot select a page. Native swipes accept only the stable
  target of their Swiper animation; controller commands name their own target.
  A matching change consumes that turn once. An already claimed turn can
  finish across a newer press, and the new swipe must claim its own target.
  Spread pairing and split-page decisions remain chapter-local. Hosts without
  verified adjacent-unit preparation retain their original optional capability.
- Continuous reading presents verified adjacent chapters in one stable List.
  Rows retain their real unit/page identity; append/prepend uses incremental data
  notifications and preserves the visible key/offset. Native leases stay bounded
  to the visible range and immediate neighbors; file/processing lookahead keeps
  its separate budget. A real drawable observation alone advances the current
  chapter/progress. Do not reopen the chapter or remount the List on crossing.
  Discovered row identities and geometry stay for that reading session: deleting
  unmeasured rows before the viewport changes ArkUI's offset estimate. Retaining
  this metadata does not retain distant native images or processing leases.
  At normal zoom, an enhanced row chooses its decode size from the measured
  List width and allocated row height, with enough source pixels for the
  visible image. The HDR overlay uses that same decode tier at reading scale.
  Zoom requests full resolution and keeps the native image as fallback when
  the full HDR overlay exceeds its existing pixel budget.
  Webtoon position follows measured page ends (falling back to the tall page
  crossing the viewport top); native decoded-pixel receipts still gate progress.
  An explicit seek retains its selected visible page until user scrolling takes over.
  Measure the continuous viewport before creating the first List, so its
  initial index and cell heights use real geometry rather than an arithmetic
  sentinel. Later sizes retain the native List/scroller and position correction.
  On ordinary entry, a guessed anchor height cannot reveal neighboring pixels.
  Neighbors still decode and report dimensions; the existing loading feedback
  remains until the original anchor row has its real allocated height, reaches
  a terminal state, or gives up the anchor to user scrolling or navigation.
  Continuous row height, native image allocation and position calculations share
  one physical-pixel-aligned size. Independent aspect-ratio/percentage layout
  must not give parent and drawable different rounded edges. Do not inflate or
  overlap images to cover the resulting seam; paged geometry stays separate.
  Explicit taps and hardware next/previous commands scroll this same native
  viewport with the same reading overlap. The host animation preference selects
  native smooth or immediate scrolling. Slider/thumbnail seeks still address
  pages, and automatic-reading dwell retains its existing per-item contract.
- The thumbnail rail requests the visible range and one neighbor on each side.
  A short return gesture reuses ready thumbnail leases in a bounded surrounding
  range. Retention does not request unseen thumbnails. Closing the rail owner
  or replacing its chapter releases those leases independently of body images.
  Thumbnail results update only their own tiles. Standalone thumbnails present
  as cover-fitted images without the geometry and visibility callbacks of a body page.
- Close/background/unit replacement retire stale demand and callbacks. Return
  restores the source window and measures the current target; entry-time
  geometry cannot stand in for the current target after layout changes.
- Display effects are optional drawable-only presentation. Tint blending, grayscale, inversion and dimming never mutate prepared files or loading/chrome/status siblings. Host preferences and window brightness remain host-owned; the all-disabled default preserves the other consumers.
- A consumer-specific capability remains optional. A host without chapter,
  processed-image or media support does not gain placeholder product actions.
  Reuse existing leaves/adapters; do not copy a complete app into the Kit.
  Hosts retain manual resume semantics and authorize automatic continuation
  from their own verified sequence; a manual catalog fallback is not automatic authorization.
- Sharing from the native More menu waits for its real disappearance before
  notifying the media action. Dismissal alone does not share; inactive/disposed
  chrome or a changed chapter, topology or navigation cancels the pending action.
  Hosts using the separate share button keep their existing direct action.

Validate every exposed behavior in one declared complete user interval, from
its source state through return. A visible missing background, premature
fullscreen/color change, black frame, wrong menu state, stale selection or
broken return rejects that required row even if the target image eventually
appears. One host's success does not accept another host's adapter. Compile all
consumers of a changed shared API; assess actual affected runtime paths without
rerunning unrelated frozen paths. Source/build, installation, named runtime
acceptance, full replacement and performance are separate conclusions.

Frozen evidence is bounded by its actual route/version/environment/dependencies.
A narrow impact review remains necessary after an indirect dependency change.
Unhit branches stay unaccepted. Do not force delays, mutate caches or sweep
input timings to manufacture those branches, or report movie FPS as app FPS.
