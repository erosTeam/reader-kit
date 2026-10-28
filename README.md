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

Before a product edit, recover the existing user behavior independently of the
patch, then trace the changed owner, callers, writers, async callbacks, parent
and sibling state, every applicable consumer, and the retained Legacy route.
Record direct/indirect exposure or a concrete reason for being unaffected.
Source-mapped cause and impact precede implementation. Build/runtime evidence
follows the coherent change; do not adjust behavior through repeated test runs.

The following are existing preservation requirements, not new feature work:

- With a valid thumbnail claim, retain the host root flight. Without it, retain
  the ordinary system entry. Never open fullscreen first and then imitate the
  flight inside Reader, wait for a second thumbnail capture before departure,
  or let a child writer change source system-bar visibility/colors early.
- Motion completion and original-image readiness are different states. Retain
  the current thumbnail/image and its loading backdrop while the same request
  is pending; canceling motion does not mean decode/presentation is complete.
  Loading feedback belongs to current request identity, not a retired callback.
  A low-resolution opening thumbnail is a preview, not a readable original: it
  retains the existing loading indicator/backdrop until this original is ready.
  A matching decode is insufficient while the entry still hides that original.
  Its existing reveal commit exposes the original and retires feedback together.
  Core may retain a displayed resource across a mode switch; a new native
  viewport still waits for its own matching decode before ending this feedback.
  The retained in-place replacement branch keeps already readable pixels.
  Before a newly mounted pager reports its real dimensions, that same feedback
  belongs to the full viewport; measured page cells take it over after layout.
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
  entire page or list by page number to obtain an update. A retained hidden
  rail keeps its decoded leases without following pages or demanding new
  ranges; showing it adopts the current position before visible following. Declarative updates
  are required; minimizing their scope does not mean prohibiting all rebuilds.
- Preload demand rolls with navigation, range, policy and unit changes; an
  initial warm window is not continuous preload. Transport warming is not
  decode or visible presentation. Hosts retain their own bounded cache owners.
- Paged reading projects host-verified neighboring chapters into the same native
  Swiper. Its render index/keys are separate from the selected chapter's local
  display index/count; every frame keeps its real unit/page identity. A boundary
  swipe or tap promotes that prepared chapter without reopening/releasing its
  decoded slots. Native insertion preserves visible keys; processing/transport
  still follow their own bounded demand and a cached decode cannot write progress.
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
  Webtoon position follows measured page ends (falling back to the tall page
  crossing the viewport top); native decoded-pixel receipts still gate progress.
  An explicit seek retains its selected visible page until user scrolling takes over.
- Close/background/unit replacement retire stale demand and callbacks. Return
  restores the source window and measures the current target; entry-time
  geometry cannot stand in for the current target after layout changes.
- A consumer-specific capability remains optional. A host without chapter,
  processed-image or media support does not gain placeholder product actions.
  Reuse existing leaves/adapters; do not copy a complete app into the Kit.
  Hosts retain manual resume semantics and authorize automatic continuation
  from their own verified sequence; a manual catalog fallback is not automatic authorization.

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
