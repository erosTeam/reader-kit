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

Run core behavioral tests with `node --test tests/reader-session.test.cjs`.
They execute the actual platform-free ArkTS core through the DevEco TypeScript
compiler. Set `READER_KIT_TYPESCRIPT` if that compiler is installed elsewhere.
Host tests do not substitute for the three apps' device acceptance.
