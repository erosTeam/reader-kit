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
const { ReaderEntryPreviewSource, ReaderEntryPreview } = evaluate(methods, {
  './ReaderEntryTransition': transition,
  '@kit.ArkUI': { FrameCallback: class {}, UIUtils: { applySync: callback => callback() } },
})
const { ReaderEntryTransition, ReaderEntryTarget, ReaderEntryRect } = transition
function pixels() {
  return { releases: 0, release() { this.releases++; return Promise.resolve() } }
}
function scenario(guard = null) {
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
  const previewSource = new ReaderEntryPreviewSource(bitmap, new ReaderEntryRect(40, 55, 100, 150), guard)
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

test('source defaults to allowing legacy callers and forwards the exact entry id', () => {
  assert.equal(new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect()).authorizeDeparture(11), true)
  const ids = []
  const value = new ReaderEntryPreviewSource(pixels(), new ReaderEntryRect(), id => { ids.push(id); return true })
  assert.equal(value.authorizeDeparture(19), true)
  assert.deepEqual(ids, [19])
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
  assert.equal(value.entry.phase, 'revealing'); assert.equal(calls, 1)
  value.animations.at(-1).onFinish(); value.preview.advance()
  assert.equal(value.entry.phase, 'finished'); assert.equal(calls, 1)
})

test('legacy null guard still starts the existing flight', () => {
  const value = scenario()
  value.preview.advance()
  assert.equal(value.entry.phase, 'moving'); assert.equal(value.animations.length, 1)
})
