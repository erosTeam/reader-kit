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
  return owner.recordNativeReady(snapshot, snapshot.topologyRevision, snapshot.navigationRevision,
    snapshot.selectionId, 20, 30, 44, 'whole', 2, 1200, 900)
}

test('live source remains owner through decode, then releases only after a matching later frame', () => {
  const owner = new ReaderLiveSourceEntry()
  assert.equal(owner.offer(state('decoding')), null)
  assert.equal(owner.readerVisible(), false)
  assert.equal(owner.hostRetained(), true)
  assert.equal(owner.offer(state()), null, 'displayed alone cannot release the live source')
  assert.equal(owner.recordNativeReady(state(), 3, 7, 11, 20, 30, 44, 'whole', 2, 1200, 901), false,
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
  assert.equal(owner.recordNativeReady(spread, 3, 7, 11, 21, 31, 45, 'whole', 1, 800, 1200), true)
  assert.ok(owner.offer(spread))
  const moved = state(); moved.navigationRevision += 1
  assert.equal(owner.offer(moved), null, 'old navigation cannot reuse ready parts')
  assert.equal(owner.recordNativeReady(moved, 3, 8, 11, 20, 999, 44, 'whole', 2, 1200, 900), false)
  const revised = state(); revised.frames[0].asset.visualRevision += 1
  assert.equal(owner.offer(revised), null, 'old native visual revision cannot release a new candidate')
  const selected = state(); selected.selectionId += 1
  assert.equal(owner.offer(selected), null, 'a new selection needs its own native receipt')
  assert.equal(owner.recordNativeReady(selected, 3, 7, 11, 20, 30, 44, 'whole', 2, 1200, 900), false,
    'a delayed old-selection callback cannot acquire the new selection')
})

function nativeImageMethods(names) {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagedViewport.ets'), 'utf8')
  const bodies = names.map(name => {
    const start = source.indexOf(`  private ${name}(`)
    assert.ok(start >= 0, name)
    const brace = source.indexOf('{', start)
    let depth = 1, end = brace + 1
    for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth-- }
    return source.slice(start, end)
  })
  const exports = {}
  vm.runInNewContext(ts.transpileModule(`class Harness { ${bodies.join('\n')} }; exports.Harness = Harness`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports, ReaderEntryAfterLayout: class { constructor(action) { this.action = action } },
  })
  return exports.Harness
}

test('one native completion merges with later displayed metadata and reveals without a second completion', () => {
  const Image = nativeImageMethods(['nativeIdentity', 'scheduleNativeStability', 'completed'])
  const image = new Image(), owner = new ReaderLiveSourceEntry(), frames = [], snapshot = state('decoding')
  snapshot.frames[0].asset.page = { width: 0, height: 0 }
  Object.assign(image, {
    frame: snapshot.frames[0], topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    slotId: 20, assetRequestId: 30, renderedFragment: 'whole', active: true,
    quarantineOriginal: true, entryMounted: true, entryOwnershipDiagnostic: false,
    decoded: false, decodedRequestId: 0, decodedWidth: 0, decodedHeight: 0,
    stableNativeIdentity: '', scheduledNativeIdentity: '', scheduledPresentationRequestId: 0,
    reportInvalidDecodedMetrics() {}, publishEntryTarget() {}, reportVisible() {},
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    onPresented() {
      snapshot.frames[0].asset.phase = 'displayed'
      snapshot.frames[0].asset.uri = 'file://first'
      snapshot.frames[0].asset.page = { width: 1200, height: 900 }
      snapshot.selectionId += 1
      image.selectionId = snapshot.selectionId
    },
    onStableNative(topology, navigation, selection, slot, request, sourceIndex, fragment, visual, width, height) {
      owner.recordNativeReady(snapshot, topology, navigation, selection, slot, request, sourceIndex,
        fragment, visual, width, height)
    },
  })
  image.completed(1200, 900)
  assert.equal(owner.offer(snapshot), null)
  assert.equal(frames.length, 1, 'first native receipt only schedules presentation')
  frames.shift()()
  assert.equal(owner.offer(snapshot), null, 'displayed state alone is not stable')
  image.scheduleNativeStability() // the real @Monitor('frame') receives the displayed snapshot
  assert.equal(frames.length, 1)
  frames.shift()()
  assert.ok(owner.offer(snapshot), 'same native Image can now hand off without a second onComplete')
})

test('retired native receipt cannot unquarantine or release a replaced request', () => {
  const Image = nativeImageMethods(['nativeIdentity', 'scheduleNativeStability'])
  const image = new Image(), owner = new ReaderLiveSourceEntry(), frames = [], snapshot = state()
  Object.assign(image, {
    frame: snapshot.frames[0], topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    slotId: 20, assetRequestId: 30, renderedFragment: 'whole', active: true,
    quarantineOriginal: true, entryMounted: true, entryOwnershipDiagnostic: false,
    decoded: true, decodedRequestId: 30, decodedWidth: 1200, decodedHeight: 900,
    stableNativeIdentity: '', scheduledNativeIdentity: '',
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    onStableNative(topology, navigation, selection, slot, request, sourceIndex, fragment, visual, width, height) {
      owner.recordNativeReady(snapshot, topology, navigation, selection, slot, request, sourceIndex,
        fragment, visual, width, height)
    },
  })
  image.scheduleNativeStability()
  assert.equal(frames.length, 1)
  image.assetRequestId = 31
  snapshot.frames[0].asset.assetRequestId = 31
  frames.shift()()
  assert.equal(image.stableNativeIdentity, '')
  assert.equal(owner.offer(snapshot), null)
})

test('queued native receipt is invalidated by a new selection with the same page and request', () => {
  const Image = nativeImageMethods(['nativeIdentity', 'scheduleNativeStability'])
  const image = new Image(), owner = new ReaderLiveSourceEntry(), frames = [], snapshot = state()
  Object.assign(image, {
    frame: snapshot.frames[0], topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    slotId: 20, assetRequestId: 30, renderedFragment: 'whole', active: true,
    quarantineOriginal: true, entryMounted: true, entryOwnershipDiagnostic: false,
    decoded: true, decodedRequestId: 30, decodedWidth: 1200, decodedHeight: 900,
    stableNativeIdentity: '', scheduledNativeIdentity: '',
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    onStableNative(topology, navigation, selection, slot, request, sourceIndex, fragment, visual, width, height) {
      owner.recordNativeReady(snapshot, topology, navigation, selection, slot, request, sourceIndex,
        fragment, visual, width, height)
    },
  })
  image.scheduleNativeStability()
  snapshot.selectionId += 1
  image.selectionId += 1
  frames.shift()()
  assert.equal(owner.offer(snapshot), null)
  image.scheduleNativeStability()
  frames.shift()()
  assert.ok(owner.offer(snapshot), 'the same node can republish after a current-selection frame')
})

test('native failure cancels a queued stability receipt before any source release', () => {
  const Image = nativeImageMethods(['nativeIdentity', 'scheduleNativeStability', 'failed'])
  const image = new Image(), owner = new ReaderLiveSourceEntry(), frames = [], snapshot = state()
  Object.assign(image, {
    frame: snapshot.frames[0], topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    slotId: 20, assetRequestId: 30, renderedFragment: 'whole', active: true,
    quarantineOriginal: true, entryMounted: true, entryOwnershipDiagnostic: false,
    decoded: true, decodedRequestId: 30, decodedWidth: 1200, decodedHeight: 900,
    stableNativeIdentity: '', scheduledNativeIdentity: '',
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    publishEntryTarget() {}, onFailed() { owner.fail() },
    onStableNative(topology, navigation, selection, slot, request, sourceIndex, fragment, visual, width, height) {
      owner.recordNativeReady(snapshot, topology, navigation, selection, slot, request, sourceIndex,
        fragment, visual, width, height)
    },
  })
  image.scheduleNativeStability()
  image.failed()
  frames.shift()()
  assert.equal(image.stableNativeIdentity, '')
  assert.equal(owner.readerVisible(), false)
  assert.equal(owner.offer(snapshot), null)
})
