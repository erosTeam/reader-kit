const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function load(name, bindings = {}) {
  const source = fs.readFileSync(path.join(__dirname, `../reader-ui/src/main/ets/${name}.ets`), 'utf8')
    .replace(/^import .*\n/gm, '')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, ...bindings })
  return exports
}

const { ReaderSelectedDrawable } = load('ReaderSelectedDrawable')
const { ReaderLiveSourceEntry } = load('ReaderLiveSourceEntry', { ReaderSelectedDrawable })

function state(phase = 'displayed') {
  return {
    phase: 'ready', kind: 'original', unit: { key: {
      scope: 'local', work: 'archive', unit: 'first', copy() { return { ...this } },
    } }, policy: { layout: 'paged' }, displayIndex: 0, displayCount: 1,
    displayKeys: ['first'], topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    frames: [{ slotId: 20, part: { sourceIndex: 44, fragment: 'whole' },
      asset: { kind: 'original', phase, uri: phase === 'displayed' ? 'file://first' : '',
        assetRequestId: 30, visualRevision: 2, page: { width: 1200, height: 900 } } }],
  }
}

function nativeReady(owner, snapshot = state()) {
  return owner.recordNativeReady(snapshot, 20, 30, 44, 'whole', 1200, 900)
}

test('live source remains owner through decode, then releases only after a matching later frame', () => {
  const owner = new ReaderLiveSourceEntry()
  assert.equal(owner.offer(state('decoding')), null)
  assert.equal(owner.readerVisible(), false)
  assert.equal(owner.hostRetained(), true)
  assert.equal(owner.offer(state()), null, 'displayed alone cannot release the live source')
  assert.equal(owner.recordNativeReady(state(), 20, 30, 44, 'whole', 1200, 901), false,
    'native completion must match the resolved page geometry')
  assert.equal(nativeReady(owner), true)
  const claim = owner.offer(state())
  assert.ok(claim)
  assert.equal(owner.reveal(claim, state()), true)
  assert.equal(owner.readerVisible(), true)
  assert.equal(owner.hostRetained(), true, 'host remains during the submitted reader reveal')
  assert.equal(owner.observedRevealFrame(claim, state()), true)
  assert.equal(owner.hostRetained(), false)
  assert.equal(owner.observedRevealFrame(claim, state()), false, 'release is once-only')
})

test('live source ignores stale selected identity and failure/cancel cannot reveal', () => {
  const owner = new ReaderLiveSourceEntry()
  nativeReady(owner)
  const claim = owner.offer(state())
  const moved = state(); moved.selectionId += 1
  assert.equal(owner.reveal(claim, moved), false)
  assert.equal(owner.readerVisible(), false)
  assert.equal(owner.reveal(claim, state()), true)
  assert.equal(owner.observedRevealFrame(claim, moved), false)
  assert.equal(owner.hostRetained(), true)
  assert.equal(owner.reconcile(moved), true)
  assert.equal(owner.readerVisible(), false)
  assert.equal(owner.offer(state()), null, 'rollback needs a fresh native receipt')
  nativeReady(owner)
  assert.equal(owner.reveal(owner.offer(state()), state()), true, 'a fresh source may take over after rollback')
  owner.cancel()
  assert.equal(owner.observedRevealFrame(claim, state()), false)

  const failure = new ReaderLiveSourceEntry()
  assert.equal(failure.fail(), true)
  assert.equal(failure.fail(), false)
  assert.equal(failure.reveal(claim, state()), false)
  assert.equal(failure.readerVisible(), false)
})

test('surface submits reveal before notifying the host to retire its live source', () => {
  const surface = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  const from = surface.indexOf('  private scheduleSelectedDrawable(')
  const to = surface.indexOf('\n  private observeLiveSourceEntryFailure(', from)
  const exports = {}
  vm.runInNewContext(ts.transpileModule(`class Harness { ${surface.slice(from, to)} }; exports.Harness = Harness`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports, ReaderSelectedDrawable,
    ReaderSelectedDrawableAfterFrame: class { constructor(action) { this.action = action } },
  })
  const frames = [], released = []
  const harness = new exports.Harness()
  const current = state()
  Object.assign(harness, {
    selectedDrawableSignals: false, liveSourceEntry: true, active: true, closing: false,
    chromeDisposed: false, liveReaderVisible: false, liveSourceEntryOwner: new ReaderLiveSourceEntry(),
    drawableScheduledKey: '', drawableSignaledKey: '',
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    session: { snapshot() { return current } },
    onLiveSourceEntryRevealFrame(claim) { released.push(claim.key()) },
  })
  harness.scheduleSelectedDrawable(state('decoding'))
  assert.equal(frames.length, 0)
  harness.scheduleSelectedDrawable(current)
  assert.equal(frames.length, 0, 'displayed without current native receipt stays held')
  nativeReady(harness.liveSourceEntryOwner, current)
  harness.scheduleSelectedDrawable(current)
  assert.equal(harness.liveReaderVisible, false)
  frames.shift()()
  assert.equal(harness.liveReaderVisible, true)
  assert.equal(released.length, 0, 'decode frame is not the host-release frame')
  assert.equal(harness.liveSourceEntryOwner.hostRetained(), true)
  frames.shift()()
  assert.equal(released.length, 1)
  assert.equal(harness.liveSourceEntryOwner.hostRetained(), false)
})

test('native receipts are bounded to the current display and every split part', () => {
  const owner = new ReaderLiveSourceEntry()
  const spread = state()
  spread.frames.push({ slotId: 21, part: { sourceIndex: 45, fragment: 'whole' },
    asset: { kind: 'original', phase: 'displayed', uri: 'file://second', assetRequestId: 31,
      visualRevision: 1, page: { width: 800, height: 1200 } } })
  nativeReady(owner, spread)
  assert.equal(owner.offer(spread), null)
  assert.equal(owner.recordNativeReady(spread, 21, 31, 45, 'whole', 800, 1200), true)
  assert.ok(owner.offer(spread))
  const moved = state(); moved.navigationRevision += 1
  assert.equal(owner.offer(moved), null, 'old navigation cannot reuse ready parts')
  assert.equal(owner.recordNativeReady(moved, 20, 999, 44, 'whole', 1200, 900), false)
})
