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
const handoff = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderRootEntryHandoff.ets'), 'utf8'), {
  './ReaderEntryTransition': entry,
})
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

function readyTarget(frame, decoded = false) {
  const target = new entry.ReaderEntryTarget(frame.part)
  target.selectionId = 2; target.topologyRevision = 1; target.navigationRevision = 1
  target.slotId = frame.slotId; target.requestId = 3; target.assetRequestId = 3
  target.layoutRevision = 1; target.contentRect = new entry.ReaderEntryRect(10, 20, 200, 300)
  target.geometryReady = true; target.decodedReady = decoded
  return target
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

test('an attested whole-page preview supplies shared entry geometry without becoming original metadata', () => {
  const frames = [frame(0), frame(1)]
  for (const value of frames) {
    value.asset.page.previewWidth = value.part.sourceIndex === 0 ? 200 : 500
    value.asset.page.previewHeight = value.part.sourceIndex === 0 ? 300 : 250
    value.asset.page.previewCoversWholePage = true
  }
  assert.equal(frames[0].asset.page.width, 0)
  assert.equal(frames[1].asset.page.height, 0)
  assert.equal(core.readerPagedFrameAspectRatio(frames[0]), 2 / 3)
  assert.equal(core.readerPagedFrameAspectRatio(frames[1]), 2)
  assert.equal(gate.ready(frames), true)
  frames[1].crop.left = 0.1
  assert.equal(gate.ready(frames), false)
})

test('the root handoff owner starts one verified-part flight then one decoded reveal', () => {
  const { state, transition } = scenario()
  const controller = new handoff.ReaderRootEntryHandoff()
  const events = []
  let arrived = null
  let commitReveal = null
  let revealed = null
  const host = {
    authorizeDeparture: value => { events.push(`authorize:${value.entryId}`); return true },
    setOpeningTarget: value => { events.push(`target:${value.contentRect.width}x${value.contentRect.height}`); return true },
    startOpening: callback => { events.push('opening'); arrived = callback },
    revealOriginal: (commit, callback) => { events.push('reveal'); commitReveal = commit; revealed = callback },
    notifyReaderImageReady: page => { events.push(`ready:${page}`) },
  }
  transition.publishTarget(readyTarget(state.frames[0]))
  controller.sync(transition, true, false, host)
  controller.sync(transition, true, false, host)
  assert.deepEqual(events, ['authorize:1', 'target:200x300', 'opening'])
  assert.equal(transition.phase, 'moving')
  arrived()
  assert.equal(transition.phase, 'waiting')
  transition.publishTarget(readyTarget(state.frames[0], true))
  controller.sync(transition, true, true, host)
  controller.sync(transition, true, true, host)
  assert.equal(transition.phase, 'waiting')
  assert.deepEqual(events, ['authorize:1', 'target:200x300', 'opening', 'reveal'])
  commitReveal()
  assert.equal(transition.phase, 'revealing')
  revealed()
  assert.equal(transition.phase, 'finished')
  assert.deepEqual(events, ['authorize:1', 'target:200x300', 'opening', 'reveal', 'ready:1'])
})

test('a cancelled entry ignores late reveal-transaction callbacks', () => {
  const { state, transition } = scenario()
  const controller = new handoff.ReaderRootEntryHandoff()
  let arrived = null
  let commitReveal = null
  let revealed = null
  let ready = 0
  const host = {
    authorizeDeparture: () => true,
    setOpeningTarget: () => true,
    startOpening: callback => { arrived = callback },
    revealOriginal: (commit, callback) => { commitReveal = commit; revealed = callback },
    notifyReaderImageReady: () => { ready++ },
  }
  transition.publishTarget(readyTarget(state.frames[0]))
  controller.sync(transition, true, false, host)
  arrived()
  transition.publishTarget(readyTarget(state.frames[0], true))
  controller.sync(transition, true, true, host)
  transition.cancel()
  commitReveal()
  revealed()
  assert.equal(transition.phase, 'cancelled')
  assert.equal(ready, 0)
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

test('entry rectangle identity tolerates one physical pixel, not real movement or invalid geometry', () => {
  const a = new entry.ReaderEntryRect(192.30769230769232,288,195.28739107572116,260.7086838942308)
  const b = new entry.ReaderEntryRect(192.30769230769232,288.3076923076923,195.30994591346155,260.41323617788464)
  assert.equal(gate.sameRect(a,b,1/3.25 + .000001), true)
  b.y += .01; assert.equal(gate.sameRect(a,b,1/3.25 + .000001), false)
  assert.equal(gate.sameRect(a,new entry.ReaderEntryRect(),1), false)
  assert.equal(gate.sameRect(a,a,NaN), false)
})

async function observedInitialEntry(layout = 'single') {
  const unit = new core.ReaderUnitKey('eh', 'observed', 'observed')
  const catalog = {
    async open(key) { return new core.ReaderUnit(key, 'observed', 2) },
    async page(value, index) { return new core.ReaderPage(value.key, `page-${index}`, index) },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only', async load(page) { return new core.ReaderAsset(`file:${page.key}`) } }
  const session = new core.ReaderPagedSession(catalog, assets)
  session.setViewportActive(true)
  const policy = new core.ReaderDisplayPolicy(); policy.layout = layout
  session.setPolicy(policy)
  await session.open(unit)
  await new Promise(resolve => setImmediate(resolve))
  let state = session.snapshot()
  const transition = new entry.ReaderEntryTransition(1, state.frames[0].part)
  transition.update(state)
  const frame = state.frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true, 600, 900)
  state = session.snapshot(); transition.update(state)
  assert.equal(transition.hasObservedInitialContent(state), false, 'decode alone is not native visibility')
  if (layout === 'continuous') {
    session.setContinuousRange(0, 0, state.topologyRevision, state.navigationRevision)
    state = session.snapshot()
    assert.equal(session.reportContinuousVisible(state.topologyRevision, state.navigationRevision,
      state.displayKeys[0], frame.slotId, frame.asset.assetRequestId, 0.5, 0.5), true)
  } else {
    assert.equal(session.reportVisible(state.selectionId, frame.slotId, frame.asset.assetRequestId, frame.part.fragment), true)
  }
  state = session.snapshot(); transition.update(state)
  assert.ok(state.observedPosition())
  return { session, state, transition }
}

function cancelledHost(events) {
  return {
    authorizeDeparture: () => { throw new Error('cancelled motion cannot authorize another flight') },
    setOpeningTarget: () => { throw new Error('cancelled motion cannot invent new geometry') },
    startOpening: () => { events.push('opening') },
    revealOriginal: () => { throw new Error('cancelled motion cannot start a new reveal') },
    notifyReaderImageReady: page => { events.push(`ready:${page}`) },
  }
}

test('real observed-before-cancel content completes only after root flight and only once', async () => {
  for (const layout of ['single', 'continuous']) {
    const { session, state, transition } = await observedInitialEntry(layout)
    transition.cancel()
    const controller = new handoff.ReaderRootEntryHandoff()
    const events = []; const host = cancelledHost(events)
    controller.startCancelledFlight(transition, true, host)
    controller.sync(transition, true, false, host, state)
    controller.sync(transition, false, true, host, state)
    assert.deepEqual(events, ['opening'])
    controller.sync(transition, true, true, host, state)
    controller.sync(transition, true, true, host, state)
    controller.startCancelledFlight(transition, true, host)
    assert.deepEqual(events, ['opening', 'ready:1'])
    session.close()
  }
})

test('cancelled readiness rejects stale identity, retired requests and nonvisible continuous content', async () => {
  const changes = [s => { s.navigationRevision++ }, s => { s.selectionId++ }, s => { s.topologyRevision++ },
    s => { s.observedAnchor = null }, s => { s.unit = new core.ReaderUnit(new core.ReaderUnitKey('other', 'work', 'unit'), 'other', 2) },
    s => { s.frames[0].slotId++ }, s => { s.frames[0].asset.requestId++ },
    s => { s.frames[0].asset.assetRequestId++ }, s => { s.frames[0].asset.assetRequestId = 0 },
    s => { s.frames[0].asset.phase = 'decoding' }, s => { s.frames[0].asset.kind = 'thumbnail' }]
  for (const change of changes) {
    const { session, state, transition } = await observedInitialEntry()
    transition.cancel(); change(state)
    const events = []; const controller = new handoff.ReaderRootEntryHandoff()
    controller.sync(transition, true, true, cancelledHost(events), state)
    assert.deepEqual(events, [])
    session.close()
  }
  const { session, state, transition } = await observedInitialEntry('continuous')
  transition.cancel(); state.visibleDisplayStart = 1; state.visibleDisplayEnd = 1
  assert.equal(transition.hasObservedInitialContent(state), false, 'selected/prefetched pixels do not prove visibility')
  session.close()
})

test('cancellation during reveal consumes actual observed content but fences late animation completion', async () => {
  const { session, state, transition } = await observedInitialEntry()
  const target = new entry.ReaderEntryTarget(state.frames[0].part)
  target.selectionId = state.selectionId; target.topologyRevision = state.topologyRevision
  target.navigationRevision = state.navigationRevision; target.slotId = state.frames[0].slotId
  target.requestId = state.frames[0].asset.requestId; target.assetRequestId = state.frames[0].asset.assetRequestId
  target.geometryReady = true; target.decodedReady = true
  target.contentRect = new entry.ReaderEntryRect(10, 20, 200, 300)
  transition.publishTarget(target)
  let arrive; let commit; let finish; const events = []
  const host = { authorizeDeparture: () => true, setOpeningTarget: () => true,
    startOpening: value => { arrive = value; events.push('opening') },
    revealOriginal: (value, callback) => { commit = value; finish = callback; events.push('reveal') },
    notifyReaderImageReady: page => { events.push(`ready:${page}`) } }
  const controller = new handoff.ReaderRootEntryHandoff()
  controller.sync(transition, true, false, host, state); arrive()
  controller.sync(transition, true, true, host, state); commit()
  transition.cancel()
  controller.sync(transition, true, true, host, state); finish()
  controller.sync(transition, true, true, host, state)
  assert.equal(transition.phase, 'cancelled')
  assert.deepEqual(events, ['opening', 'reveal', 'ready:1'])
  session.close()
})

test('Back fences cancelled readiness even when exact original content was already observed', async () => {
  const { session, state, transition } = await observedInitialEntry('continuous')
  const controller = new handoff.ReaderRootEntryHandoff(); const events = []
  assert.equal(controller.requestReverse(transition, true, () => true), true)
  controller.sync(transition, true, true, cancelledHost(events), state)
  controller.startCancelledFlight(transition, true, cancelledHost(events))
  assert.deepEqual(events, [])
  session.close()
})
