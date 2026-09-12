const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
const uiPath = path.join(__dirname, '../reader-ui/src/main/ets')
function evaluate(source, imports) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, {
    exports, require: name => { assert.ok(name in imports, name); return imports[name] },
    ObservedV2: value => value, ComponentV2: value => value,
    Trace() {}, Param() {}, Require() {}, Local() {}, Monitor: () => () => {},
    Curve: { FastOutSlowIn: 'ease', Linear: 'linear' }, console: { info() {} },
  })
  return exports
}
const transition = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderEntryTransition.ets'), 'utf8'), { '@reader-kit/core': core })
const source = fs.readFileSync(path.join(uiPath, 'ReaderEntryPreview.ets'), 'utf8')
// Run the real source class and presenter methods, excluding only declarative build syntax.
// Platform animation is a callback recorder: these are state/ownership tests, not visual acceptance.
const methods = source.slice(0, source.indexOf('\n  build() {')).replace('export struct ReaderEntryPreview {', 'export class ReaderEntryPreview {') + '\n}\n'
let syncDepth = 0
const { ReaderEntryPreviewSource, ReaderEntryPreview } = evaluate(methods, {
  './ReaderEntryTransition': transition,
  '@kit.ArkUI': { FrameCallback: class {}, UIUtils: { applySync: callback => {
    syncDepth++
    try { callback() } finally { syncDepth-- }
  } } },
})
const { ReaderEntryTransition, ReaderEntryTarget, ReaderEntryRect } = transition
function pixels() {
  return { releases: 0, release() { this.releases++; return Promise.resolve() } }
}
function scenario(guard = null, coverage = undefined) {
  const part = new core.ReaderDisplayPart(new core.ReaderUnitKey('nh', 'work', 'work'), 'page-0', 0)
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.selectionId = 2; state.topologyRevision = 1; state.navigationRevision = 1
  const asset = new core.ReaderSnapshot(); asset.requestId = 3; asset.assetRequestId = 3
  state.frames = [new core.ReaderPagedFrame(7, part, asset)]
  const entry = new ReaderEntryTransition(11, part); entry.update(state)
  const target = new ReaderEntryTarget(part)
  target.selectionId = 2; target.topologyRevision = 1; target.navigationRevision = 1
  target.slotId = 7; target.requestId = 3; target.assetRequestId = 3; target.layoutRevision = 1
  target.geometryReady = true; target.contentRect = new ReaderEntryRect(100, 150, 400, 600)
  entry.publishTarget(target)
  const bitmap = pixels()
  const previewSource = new ReaderEntryPreviewSource(bitmap, new ReaderEntryRect(40, 55, 100, 150), guard, coverage)
  const preview = new ReaderEntryPreview()
  preview.entry = entry; preview.source = previewSource; preview.mounted = true; preview.firstFrame = true
  preview.x = 40; preview.y = 55
  const animations = []
  preview.getUIContext = () => ({ animateTo(options, callback) { animations.push(options); callback() } })
  return { entry, preview, previewSource, bitmap, animations, target }
}
function unchangedFlight(value) {
  assert.equal(value.animations.length, 0)
  assert.equal(value.preview.destination, null); assert.equal(value.preview.epoch, 0)
  assert.equal(value.preview.x, 40); assert.equal(value.preview.y, 55); assert.equal(value.preview.previewScale, 1)
  assert.equal(value.previewSource.rect.x, 40); assert.equal(value.previewSource.rect.y, 55)
}

test('continuous clip preserves the complete long-image flight scale and independent window clip', () => {
  const value = scenario(null, 'whole-page')
  value.target.contentRect = new ReaderEntryRect(0, -300, 400, 2400)
  value.target.clipRect = new ReaderEntryRect(0, 100, 400, 700)
  value.entry.publishTarget(value.target)
  value.preview.source.rect = new ReaderEntryRect(40, 55, 100, 600)
  value.preview.advance()
  assert.equal(value.preview.previewScale, 4)
  assert.equal(value.preview.destination.height, 2400)
  assert.equal(value.preview.y, -300)
  assert.equal(value.preview.previewClip().height, 700)
  assert.equal(value.animations[0].duration, 280)
  value.target.clipRect.y = 101
  value.entry.publishTarget(value.target); value.preview.advance()
  assert.equal(value.entry.phase, 'cancelled')
})

test('unknown continuous preview stays in its visible container without changing original geometry', () => {
  const value = scenario(null, 'unknown')
  // Actual N197 source and original dimensions; exercise real advance, not a UI acceptance fixture.
  value.preview.source.rect = new ReaderEntryRect(764, 1960, 317, 488)
  value.target.contentRect = new ReaderEntryRect(0, 0, 1260, 16756.25)
  value.target.clipRect = new ReaderEntryRect(0, 124, 1260, 2596)
  value.entry.publishTarget(value.target)
  value.preview.advance()
  const height = 488 * value.preview.previewScale
  assert.equal(value.preview.previewScale, 1260 / 317)
  assert.ok(value.preview.y >= 124)
  assert.ok(value.preview.y + height <= 2720)
  assert.equal(value.preview.destination.height, 16756.25)
  assert.equal(value.entry.target.contentRect.height, 16756.25)
  assert.equal(value.entry.target.contentRect.y, 0)
  assert.equal(value.animations[0].duration, 280)
  value.animations[0].onFinish()
  value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
  assert.equal(value.entry.phase, 'finished')
  assert.equal(value.preview.previewOpacity, 0)
  assert.equal(value.animations.at(-1).duration, 0)
})

test('unknown continuous preview rejects an empty visible container before flight', () => {
  const value = scenario(null, 'unknown')
  value.target.contentRect = new ReaderEntryRect(0, 3000, 400, 2400)
  value.target.clipRect = new ReaderEntryRect(0, 100, 400, 700)
  value.entry.publishTarget(value.target)
  value.preview.advance()
  assert.equal(value.entry.phase, 'cancelled')
  assert.equal(value.animations.length, 0)
  assert.equal(value.entry.target.contentRect.y, 3000)
})

test('source defaults to allowing legacy callers and forwards the exact entry id', () => {
  assert.equal(new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect()).authorizeDeparture(11), true)
  const ids = []
  const value = new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect(), id => { ids.push(id); return true })
  assert.equal(value.authorizeDeparture(19), true)
  assert.deepEqual(ids, [19])
})

test('source coverage defaults to unknown and preserves an explicit producer declaration independently of ratio', () => {
  const rect = new ReaderEntryRect(0, 0, 100, 150)
  assert.equal(new ReaderEntryPreviewSource(pixels(), rect).coverage, 'unknown')
  for (const coverage of ['unknown', 'whole-page']) {
    const value = new ReaderEntryPreviewSource(pixels(), rect, null, coverage)
    assert.equal(value.coverage, coverage)
    assert.equal(value.rect, rect)
    value.release()
    assert.equal(value.coverage, coverage)
  }
})

test('source denies false, thrown, released and synchronously released authorization', () => {
  for (const guard of [() => false, () => { throw Error('source gone') }]) {
    assert.equal(new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect(), guard).authorizeDeparture(1), false)
  }
  let calls = 0
  const bitmap = pixels()
  const value = new ReaderEntryPreviewSource(bitmap, new ReaderEntryRect(), () => { calls++; return true })
  value.release(); value.release()
  assert.equal(value.authorizeDeparture(1), false); assert.equal(calls, 0); assert.equal(bitmap.releases, 1)
  const reentrant = new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect(), () => { reentrant.release(); return true })
  assert.equal(reentrant.authorizeDeparture(1), false)
})

test('actual advance waits for initial frame and target geometry before consulting the source', () => {
  let calls = 0
  const value = scenario(() => { calls++; return true })
  value.preview.firstFrame = false; value.preview.advance()
  value.preview.firstFrame = true; value.entry.target = null; value.preview.advance()
  value.target.geometryReady = false; value.entry.publishTarget(value.target); value.preview.advance()
  assert.equal(calls, 0); assert.equal(value.entry.phase, 'layout'); unchangedFlight(value)
})

test('actual advance denies departure before any destination, epoch or animation mutation', () => {
  for (const guard of [() => false, () => { throw Error('invalid viewport') }]) {
    const value = scenario(guard)
    value.preview.advance(); value.preview.advance()
    assert.equal(value.entry.phase, 'cancelled'); unchangedFlight(value)
  }
  const released = scenario(); released.previewSource.release(); released.preview.advance()
  assert.equal(released.entry.phase, 'cancelled'); unchangedFlight(released)
})

test('a guard that cancels or retires the presenter cannot start it by returning true', () => {
  const cancelled = scenario(() => { cancelled.entry.cancel(); return true })
  cancelled.preview.advance()
  assert.equal(cancelled.entry.phase, 'cancelled'); unchangedFlight(cancelled)
  const retired = scenario(() => { retired.preview.aboutToDisappear(); return true })
  retired.preview.advance()
  assert.equal(retired.entry.phase, 'cancelled'); assert.equal(retired.animations.length, 0)
  assert.equal(retired.preview.destination, null)
})

test('a synchronously replaced entry cannot use authorization for the previous entry', () => {
  const value = scenario(() => { value.preview.entry = replacement.entry; return true })
  const replacement = scenario()
  value.preview.advance()
  unchangedFlight(value)
  assert.equal(value.entry.phase, 'layout'); assert.equal(replacement.entry.phase, 'layout')
})

test('allowed departure authorizes once; duplicate advances and decode handoff never reuse the guard', () => {
  let calls = 0
  const value = scenario(id => {
    calls++; assert.equal(id, 11); unchangedFlight(value); return true
  })
  value.preview.advance(); value.preview.advance()
  assert.equal(value.entry.phase, 'moving'); assert.equal(calls, 1); assert.equal(value.animations.length, 1)
  value.animations[0].onFinish()
  assert.equal(value.entry.phase, 'waiting'); assert.equal(calls, 1)
  value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
  assert.equal(value.entry.phase, 'finished'); assert.equal(calls, 1)
  assert.equal(value.animations.at(-1).onFinish, undefined)
  value.preview.advance()
  assert.equal(value.entry.phase, 'finished'); assert.equal(calls, 1)
})

test('legacy null guard still starts the existing flight', () => {
  const value = scenario()
  value.preview.advance()
  assert.equal(value.entry.phase, 'moving'); assert.equal(value.animations.length, 1)
})

for (const coverage of ['unknown', 'whole-page']) {
  test(`${coverage}: actual advance preserves flight and selects the declared handoff opacity`, () => {
    const value = scenario(null, coverage)
    assert.equal(value.preview.previewOpacity, 1)
    value.preview.advance()
    assert.equal(value.animations[0].duration, 280)
    assert.equal(value.preview.previewScale, 4)
    assert.equal(value.preview.x, 100); assert.equal(value.preview.y, 150)
    assert.equal(value.preview.previewOpacity, 1)
    value.animations[0].onFinish()
    assert.equal(value.entry.phase, 'waiting')
    assert.equal(value.preview.previewOpacity, 1)
    value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
    const reveal = value.animations.at(-1)
    assert.equal(reveal.duration, coverage === 'unknown' ? 0 : 140)
    assert.equal(reveal.curve, coverage === 'unknown' ? undefined : 'linear')
    assert.equal(value.entry.phase, coverage === 'unknown' ? 'finished' : 'revealing')
    assert.equal(value.entry.selectedOpacity, 1)
    assert.equal(value.preview.previewOpacity, coverage === 'unknown' ? 0 : 1)
    const count = value.animations.length
    value.preview.advance()
    assert.equal(value.animations.length, count)
    if (coverage === 'whole-page') reveal.onFinish()
    else assert.equal(reveal.onFinish, undefined)
    value.preview.advance()
    assert.equal(value.entry.phase, 'finished'); assert.equal(value.entry.pending(), false)
    assert.equal(value.animations.length, count)
  })

  test(`${coverage}: cancelled flight and retired waiting presenters cannot revive the entry`, () => {
    const flight = scenario(null, coverage)
    flight.preview.advance(); flight.entry.cancel(); flight.animations[0].onFinish(); flight.preview.advance()
    assert.equal(flight.entry.phase, 'cancelled'); assert.equal(flight.entry.pending(), false)
    assert.equal(flight.animations.length, 1); assert.equal(flight.preview.previewOpacity, 1)
    for (const retire of [value => value.entry.cancel(), value => value.preview.aboutToDisappear()]) {
      const value = scenario(null, coverage)
      value.preview.advance(); value.animations[0].onFinish()
      const count = value.animations.length
      retire(value)
      value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
      assert.equal(value.entry.phase, 'cancelled'); assert.equal(value.entry.pending(), false)
      assert.equal(value.animations.length, count)
    }
  })
}

test('whole-page: retired and stale reveal callbacks retain their existing fences', () => {
  for (const retire of [value => value.entry.cancel(), value => value.preview.aboutToDisappear()]) {
    const value = scenario(null, 'whole-page')
    value.preview.advance(); value.animations[0].onFinish()
    value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
    const finish = value.animations.at(-1).onFinish
    const count = value.animations.length
    retire(value); finish(); value.preview.advance()
    assert.equal(value.entry.phase, 'cancelled'); assert.equal(value.entry.pending(), false)
    assert.equal(value.animations.length, count)
  }
  const stale = scenario(null, 'whole-page')
  stale.preview.advance(); stale.animations[0].onFinish()
  stale.target.decodedReady = true; stale.entry.publishTarget(stale.target); stale.preview.advance()
  const staleFinish = stale.animations.at(-1).onFinish
  stale.preview.epoch++
  staleFinish()
  assert.equal(stale.entry.phase, 'revealing')
})

test('unknown: reveal and finish execute inside one zero-duration synchronous UI commit', () => {
  const value = scenario()
  value.preview.advance(); value.animations[0].onFinish()
  let duration = null
  const calls = []
  for (const method of ['reveal', 'finish']) {
    const actual = value.entry[method].bind(value.entry)
    value.entry[method] = () => {
      calls.push({ method, duration, syncDepth })
      actual()
    }
  }
  value.preview.getUIContext = () => ({ animateTo(options, callback) {
    assert.equal(options.onFinish, undefined)
    duration = options.duration
    callback()
    assert.equal(value.entry.phase, 'finished')
    assert.equal(value.entry.selectedOpacity, 1); assert.equal(value.preview.previewOpacity, 0)
    duration = null
  } })
  value.target.decodedReady = true; value.entry.publishTarget(value.target); value.preview.advance()
  assert.deepEqual(calls, [
    { method: 'reveal', duration: 0, syncDepth: 1 },
    { method: 'finish', duration: 0, syncDepth: 1 },
  ])
})

test('unknown: already decoded content still waits for flight arrival and commits without a completion callback', () => {
  const value = scenario()
  value.target.decodedReady = true; value.entry.publishTarget(value.target)
  value.preview.advance(); value.preview.advance()
  assert.equal(value.entry.phase, 'moving'); assert.equal(value.entry.selectedOpacity, 0)
  assert.equal(value.entry.neighborOpacity, 0); assert.equal(value.preview.previewOpacity, 1)
  assert.equal(value.animations.length, 1)
  value.animations[0].onFinish()
  assert.deepEqual(value.animations.map(animation => animation.duration), [280, 140, 0])
  assert.equal(value.animations.at(-1).onFinish, undefined)
  assert.equal(value.entry.phase, 'finished'); assert.equal(value.entry.selectedOpacity, 1)
  assert.equal(value.entry.neighborOpacity, 1); assert.equal(value.preview.previewOpacity, 0)
  assert.equal(value.bitmap.releases, 0) // The host still owns snapshot release.
  value.animations[0].onFinish(); value.preview.advance(); value.preview.aboutToDisappear()
  assert.equal(value.entry.phase, 'finished'); assert.equal(value.animations.length, 3)
})

test('unknown: failed or changed landing geometry cancels without scheduling the atomic handoff', () => {
  for (const invalidate of [target => { target.failed = true }, target => { target.contentRect.x += 1 }]) {
    const value = scenario()
    value.preview.advance(); value.animations[0].onFinish()
    value.target.decodedReady = true; invalidate(value.target)
    value.entry.publishTarget(value.target); value.preview.advance()
    assert.equal(value.entry.phase, 'cancelled')
    assert.deepEqual(value.animations.map(animation => animation.duration), [280, 140])
    assert.equal(value.entry.selectedOpacity, 1); assert.equal(value.entry.neighborOpacity, 1)
  }
})
