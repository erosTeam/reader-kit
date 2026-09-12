const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
function evaluate(source, imports) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, { exports, require: name => {
    assert.ok(name in imports, name)
    return imports[name]
  }, ObservedV2: value => value, Trace: () => {}, console: { info() {} } })
  return exports
}
const uiPath = path.join(__dirname, '../reader-ui/src/main/ets')
const entry = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderEntryTransition.ets'), 'utf8'), { '@reader-kit/core': core })
// Execute the actual platform-free declarations preceding ArkUI structs. This tests decisions and
// request fencing, not source shape, layout geometry, rendering, or device acceptance.
const viewport = fs.readFileSync(path.join(uiPath, 'ReaderPagedViewport.ets'), 'utf8')
const { ReaderEntryGeometryGate: gate } = evaluate(viewport.slice(0, viewport.indexOf('@ComponentV2')), {
  '@reader-kit/core': core, './ReaderEntryTransition': entry,
  '@kit.ArkUI': { FrameCallback: class {} },
})
function frame(index = 0, width = 0, height = 0) {
  const unit = new core.ReaderUnitKey('eh', 'work', 'work')
  const asset = new core.ReaderSnapshot()
  asset.requestId = 3; asset.assetRequestId = 3; asset.kind = 'original'; asset.phase = 'decoding'
  asset.page = new core.ReaderPage(unit, `page-${index}`, index)
  asset.page.width = width; asset.page.height = height
  asset.page.thumbnail.width = 200; asset.page.thumbnail.height = 300
  return new core.ReaderPagedFrame(index + 1, new core.ReaderDisplayPart(unit, asset.page.key, index), asset)
}
function scenario() {
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.selectionId = 2; state.navigationRevision = 1; state.topologyRevision = 1
  state.frames = [frame(), frame(1)]
  const transition = new entry.ReaderEntryTransition(1, state.frames[0].part)
  transition.update(state)
  return { state, transition }
}

test('zero original metadata waits only in initial layout and never uses thumbnail dimensions', () => {
  for (const dimensions of [[0, 0], [0, 900], [600, 0]]) {
    const frames = [frame(0, ...dimensions)]
    assert.equal(gate.frame(frames[0]), 'unknown')
    assert.equal(gate.ready(frames), false)
    assert.equal(gate.cancel(frames, 'layout'), false)
    for (const phase of ['moving', 'waiting', 'revealing']) assert.equal(gate.cancel(frames, phase), true)
  }
  assert.equal(gate.ready([]), false)
})

test('nonfinite, negative, failed and thumbnail frames cannot establish entry geometry', () => {
  for (const dimensions of [[NaN, 900], [600, Infinity], [-1, 900], [600, -1]]) {
    assert.equal(gate.cancel([frame(0, ...dimensions)], 'layout'), true)
  }
  for (const change of [value => { value.asset.phase = 'failed' }, value => { value.asset.kind = 'thumbnail' }]) {
    const value = frame(0, 600, 900); change(value)
    assert.equal(gate.ready([value]), false)
    assert.equal(gate.cancel([value], 'layout'), true)
  }
})

test('spread requires every ratio contributor; source readiness cannot conceal an unknown neighbor', () => {
  const frames = [frame(0, 600, 900), frame(1)]
  assert.equal(gate.ready(frames), false)
  assert.equal(gate.cancel(frames, 'layout'), false)
  frames[1].asset.page.width = 1200; frames[1].asset.page.height = 500
  assert.equal(gate.ready(frames), true)
})

test('invalid native metrics cancel current source or neighbor without inventing decode failure or geometry', () => {
  for (const index of [0, 1]) {
    const { state, transition } = scenario()
    const current = state.frames[index]
    gate.invalidDecoded(transition, state, current.slotId, current.asset.requestId, current.asset.assetRequestId)
    assert.equal(transition.phase, 'cancelled')
    assert.equal(transition.selectedOpacity, 1); assert.equal(transition.neighborOpacity, 1)
    assert.equal(transition.target.geometryReady, false); assert.equal(transition.target.failed, false)
    assert.equal(state.frames[index].asset.phase, 'decoding')
  }
})

test('retired decoder and stale snapshot cannot cancel the current entry', () => {
  for (const values of [[1, 2, 3], [1, 3, 2], [99, 3, 3], [1, 0, 0]]) {
    const { state, transition } = scenario()
    gate.invalidDecoded(transition, state, ...values)
    assert.equal(transition.phase, 'layout'); assert.equal(transition.target, null)
  }
  for (const field of ['selectionId', 'topologyRevision']) {
    const { state, transition } = scenario()
    const stale = state.forItem('missing')
    stale.frames = state.frames
    state[field]++; transition.update(state)
    gate.invalidDecoded(transition, stale, 1, 3, 3)
    assert.equal(transition.phase, 'layout'); assert.equal(transition.target, null)
    gate.invalidDecoded(transition, state, 1, 3, 3)
    assert.equal(transition.phase, 'cancelled')
  }
})

test('real session presentation refines zero metadata without changing navigation or fabricating visibility', async () => {
  const unit = new core.ReaderUnitKey('eh', 'work', 'work')
  const catalog = {
    async open(key) { return new core.ReaderUnit(key, 'work', 2) },
    async page(value, index) { return new core.ReaderPage(value.key, `page-${index}`, index) },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only', async load(page) { return new core.ReaderAsset(`file:${page.key}`) } }
  const session = new core.ReaderPagedSession(catalog, assets)
  const policy = new core.ReaderDisplayPolicy(); policy.layout = 'spread'
  session.setPolicy(policy)
  await session.open(unit)
  await new Promise(resolve => setImmediate(resolve))
  const before = session.snapshot()
  assert.equal(gate.ready(before.frames), false)
  const observed = []
  session.subscribe(snapshot => observed.push(snapshot))
  const first = before.frames[0]
  session.reportPresentation(first.slotId, first.asset.assetRequestId, true, 600, 900)
  assert.equal(gate.ready(session.snapshot().frames), false)
  // The old callback snapshot remains zero even after core has accepted native metrics.
  assert.equal(before.frames[0].asset.page.width, 0)
  assert.equal(gate.cancel(before.frames, 'layout'), false)
  const second = session.snapshot().frames[1]
  session.reportPresentation(second.slotId, second.asset.assetRequestId, true, 1200, 500)
  const after = session.snapshot()
  assert.equal(gate.ready(after.frames), true)
  assert.equal(after.navigationRevision, before.navigationRevision)
  assert.equal(after.topologyRevision, before.topologyRevision)
  assert.ok(after.selectionId > before.selectionId)
  assert.equal(after.observedAnchor, null)
  assert.ok(observed.some(snapshot => snapshot.frames[0].asset.phase === 'displayed' && snapshot.frames[0].asset.page.width === 0))
  assert.ok(observed.every(snapshot => !gate.cancel(snapshot.frames, 'layout')))
  session.close()
})
