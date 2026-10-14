const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function load(name, bindings = {}) {
  const source = fs.readFileSync(path.join(__dirname, `../reader-ui/src/main/ets/${name}.ets`), 'utf8')
    .replace(/^import .*/gm, '')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, ...bindings })
  return exports
}

const { ReaderPositionHandoff } = load('ReaderPositionHandoff', {
  ReaderSelectedDrawable: { from() { return null } },
})
const { ReaderBoundarySwipe } = load('ReaderBoundarySwipe')

function part(slotId, requestId, sourceIndex, visualRevision = 0) {
  return { slotId, part: { sourceIndex, fragment: 'whole' },
    asset: { assetRequestId: requestId, visualRevision, phase: 'displayed', kind: 'original', uri: 'file://ready' } }
}

function snapshot() {
  const old = [part(1, 3, 49)]
  const target = [part(2, 4, 50), part(3, 5, 51)]
  return { phase: 'ready', topologyRevision: 8, navigationRevision: 10, selectionId: 6,
    displayIndex: 0, displayCount: 2, displayKeys: ['old', 'target'], kind: 'original',
    policy: { layout: 'spread' }, unit: { key: { scope: 's', work: 'w', unit: 'u' } },
    frames: old, forItem(key) { return { ...this, frames: key === 'old' ? old : target } } }
}

test('whole-page handoff keeps old and target receipts separate across split parts', () => {
  const state = snapshot()
  const claim = new ReaderPositionHandoff(9, 1, 8, 10, state)
  assert.equal(claim.oldNodeReady(), false)
  assert.equal(claim.oldNodeStable(8, 10, 5, 1, 3, 49, 'whole', 0), false, 'stale selection')
  assert.equal(claim.oldNodeStable(8, 10, 6, 1, 3, 49, 'whole', 0), true)
  assert.equal(claim.targetNodeStable(state, 8, 10, 6, 2, 4, 50, 'whole', 0), false,
    'decoded target is not enough without its presentation receipt')
  claim.targetNodePresented(state, 2, 4, true)
  claim.targetNodePresented(state, 3, 5, true)
  assert.equal(claim.targetStableReady(state), false, 'second spread part is still unready')
  assert.equal(claim.targetNodeStable(state, 8, 10, 6, 3, 5, 51, 'whole', 0), true)
  assert.equal(claim.targetStableReady(state), true)
})

test('native selected target cannot retire old owner on stale revision or one ready part', () => {
  const before = snapshot()
  const claim = new ReaderPositionHandoff(9, 1, 8, 10, before, null, true)
  const selected = { ...before, displayIndex: 1, navigationRevision: 11, selectionId: 7,
    frames: before.forItem('target').frames }
  claim.nativeNodePresented(selected, 'target', 2, 4, true)
  claim.nativeNodePresented(selected, 'target', 3, 5, true)
  assert.equal(claim.nativeNodeStable(selected, 'target', 8, 11, 6, 2, 4, 50, 'whole', 0), false)
  assert.equal(claim.nativeNodeStable(selected, 'target', 8, 11, 7, 2, 4, 50, 'whole', 1), false)
  assert.equal(claim.nativeNodeStable(selected, 'target', 8, 11, 7, 2, 4, 50, 'whole', 0), false)
  assert.equal(claim.nativeNodeStable(selected, 'target', 8, 11, 7, 3, 5, 51, 'whole', 0), true)
})

function pagerMethods(names) {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagerSurface.ets'), 'utf8')
  const bodies = names.map(name => {
    const start = source.indexOf(`  private ${name}(`, source.indexOf('struct ReaderNativePager'))
    assert.ok(start >= 0, name)
    const brace = source.indexOf('{', start)
    let depth = 1, end = brace + 1
    for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth-- }
    return source.slice(start, end)
  })
  const exports = {}
  vm.runInNewContext(ts.transpileModule(`class Harness { ${bodies.join('\n')} }; exports.Harness = Harness`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, ReaderBoundarySwipe,
    ReaderSelectedDrawable: { from(value) { return value.frames.every(frame =>
      frame.asset.phase === 'displayed') ? {} : null } },
    TouchType: { Down: 'down', Up: 'up', Cancel: 'cancel' },
  })
  return exports.Harness
}

test('slow native swipe is admitted as a deferred old-owner command, not direct selection', () => {
  const Pager = pagerMethods(['nativePart', 'recordNativeStable', 'nativeTargetReady',
    'nativeAdjacentReady', 'handleBoundaryTouch'])
  const pager = new Pager(), state = snapshot(), deferred = [], boundaries = []
  Object.assign(pager, { snapshot: state, active: true, inputLocked: false, moving: false,
    createdRevision: 8, nativeReadyRevision: 0, nativeStableParts: new Set(),
    deferredSwipe: new ReaderBoundarySwipe(), boundarySwipe: new ReaderBoundarySwipe(),
    deferredGestureActive: false,
    onDeferredSwipe(...args) { deferred.push(args) }, onBoundary(...args) { boundaries.push(args) } })
  assert.equal(pager.nativeAdjacentReady(), false)
  const touch = (type, x) => ({ type, touches: type === 'up' ? [] : [{}],
    changedTouches: [{ windowX: x, windowY: 100 }] })
  pager.handleBoundaryTouch(touch('down', 100))
  assert.equal(pager.deferredGestureActive, true)
  pager.handleBoundaryTouch(touch('up', 0))
  assert.deepEqual(deferred, [['next', 8, 10]])
  assert.equal(boundaries.length, 0)
  pager.recordNativeStable('target', 8, 10, 6, 2, 4, 50, 'whole', 0)
  assert.equal(pager.nativeAdjacentReady(), false, 'a spread needs both original parts')
  pager.recordNativeStable('target', 8, 10, 6, 3, 5, 51, 'whole', 0)
  assert.equal(pager.nativeAdjacentReady(), true)
  pager.handleBoundaryTouch(touch('down', 100))
  assert.equal(pager.deferredGestureActive, false)
  pager.handleBoundaryTouch(touch('up', 0))
  assert.equal(deferred.length, 1, 'ready target keeps native Swiper ownership')
})

test('paged original quarantine is paired with old whole-page admission and host command routing', () => {
  const viewport = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagedViewport.ets'), 'utf8')
  const pager = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagerSurface.ets'), 'utf8')
  const surface = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(viewport, /guardUndecodedOriginal: true/)
  assert.match(viewport, /this\.stableDrawableIdentity !== this\.drawableIdentity\(\) \? 0 : 1/)
  assert.match(pager, /\.disableSwipe\([\s\S]*?!this\.nativeAdjacentReady\(\)\)/)
  assert.match(pager, /!this\.positionHandoff\?\.oldNodeReady\(\)/)
  assert.match(pager, /this\.onDeferredSwipe\(deferred, this\.boundaryTopology, this\.boundaryNavigation\)/)
  assert.match(surface, /onDeferredSwipe:[\s\S]*?this\.requestMove\(direction\)/)
})
