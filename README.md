# Reader Kit

Shared HarmonyOS reader integration for NextN, NextE and Koma. The current
host integrations include ordinary Shared routes and retained Legacy fallback;
the early D1 claim that only Debug routes exist is historical. Full replacement,
all-provider coverage and performance superiority are not established by this
README. Runtime acceptance belongs to the active host work order and its bound
receipts, not a test count or a package version.

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
- Keep one canonical value for a setting. The row label, menu check, bottom
  control and adopted session behavior must project that value. Shared routing
  must preserve existing button/menu semantics, options and live updates.
- Page selection updates local observed state. Retain the reading session,
  thumbnail rail, scroller and unrelated image nodes; do not key/remount an
  entire page or list by page number to obtain an update. Declarative updates
  are required; minimizing their scope does not mean prohibiting all rebuilds.
- Preload demand rolls with navigation, range, policy and unit changes; an
  initial warm window is not continuous preload. Transport warming is not
  decode or visible presentation. Hosts retain their own bounded cache owners.
- Close/background/unit replacement retire stale demand and callbacks. Return
  restores the source window and measures the current target; entry-time
  geometry cannot stand in for the current target after layout changes.
- A consumer-specific capability remains optional. A host without chapter,
  processed-image or media support does not gain placeholder product actions.
  Reuse existing leaves/adapters; do not copy a complete app into the Kit.
  Chapter requests retain their `explicit` or `boundary` origin. Hosts keep
  manual resume semantics and authorize automatic continuation from their own
  verified sequence; a manual catalog fallback is not automatic authorization.
  The host resolves the target page, and `ReaderPagedSession.open` can apply a
  one-shot page-end position for backward continuation. This position survives
  catalog retry without becoming a persisted preference or a synthetic observation.

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

## Integration and local development

Each host has a `third_party/reader-kit` checkout. Verify its real path, HEAD,
working diff and local OHPM dependency before building; the former D1 sibling
layout and “no CI wiring” statements do not describe every current consumer.
Use that host's documented signed-build entrypoint and install policy. Do not
publish, change a host default or migrate data merely because the Kit builds.

Host Want/Debug routes are diagnostic capabilities. Keep their override and
write permissions explicit; a successful Debug route does not prove ordinary
persisted backend selection or the system animation of a no-thumbnail entry.

Shared UI accepts host settings, preferences, observed progress, title,
chapters, preload, media and processed-variant capabilities through existing
ports. The host owns persistence and I/O; the core never learns an app's
preference schema or writes its account/download data. Native displayed
original content, not thumbnail metadata or a commanded anchor, is readiness
and observed-progress evidence.

## Historical design and evidence

The original dated D1–D12 notes, API rationale and bounded device observations
are preserved byte-for-byte in
[the historical README](docs/archive/README-through-20260914.md). Their old
“current”, “next”, default-device and production-route statements are not
execution instructions. Consult the dated section for technical history,
then confirm current source and the active host receipt before using it.

Historical archive SHA-256:
`3f91ac8d5a0dfb5519366bc4dc70ccaeea81c8e556ce78424979d00aab0fc69e`.
