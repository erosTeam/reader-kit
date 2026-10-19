const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
const exportsUI = {}
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderEntryTransition.ets'), 'utf8')
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
}).outputText, {
  exports: exportsUI, require: name => { assert.equal(name, '@reader-kit/core'); return core },
  ObservedV2: value => value, Trace: () => {},
})
const { ReaderEntryTransition, ReaderEntryTarget, ReaderEntryRect } = exportsUI
function scenario() {
  const part = new core.ReaderDisplayPart(new core.ReaderUnitKey('nh', '678049', '678049'), 'page1', 0)
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.selectionId = 2; state.navigationRevision = 1; state.topologyRevision = 1
  const asset = new (load('ReaderSession').ReaderSnapshot)()
  asset.requestId = 3; asset.assetRequestId = 3
  state.frames = [new core.ReaderPagedFrame(7, part, asset)]
  const entry = new ReaderEntryTransition(1, part)
  entry.update(state)
  const target = () => {
    const result = new ReaderEntryTarget(part)
    result.slotId = 7; result.requestId = state.frames[0].asset.requestId
    result.assetRequestId = state.frames[0].asset.assetRequestId; result.navigationRevision = state.navigationRevision
    result.selectionId = state.selectionId; result.topologyRevision = state.topologyRevision
    result.layoutRevision = 1; result.geometryReady = true
    result.contentRect = new ReaderEntryRect(10, 20, 50, 600)
    return result
  }
  return { part, state, entry, target }
}

test('entry waits for actual decode after movement, then finishes the same selected page', () => {
  const { entry, target, part } = scenario()
  entry.publishTarget(target()); entry.beginMove(); entry.arrived(); entry.reveal()
  assert.equal(entry.phase, 'waiting'); assert.equal(entry.opacity(part), 0)
  const decoded = target(); decoded.decodedReady = true
  entry.publishTarget(decoded); entry.reveal()
  assert.equal(entry.phase, 'revealing'); assert.equal(entry.opacity(part), 1)
  entry.finish(); assert.equal(entry.phase, 'finished')
})

test('stale request and wrong original page cannot replace the published target', () => {
  const { entry, target } = scenario()
  for (const change of [t => t.requestId++, t => t.assetRequestId++, t => t.slotId++, t => t.selectionId++,
    t => t.navigationRevision++, t => t.topologyRevision++, t => t.part.sourceIndex++,
    t => t.part.pageKey = 'other', t => t.part.fragment = 'right']) {
    const stale = target(); change(stale); entry.publishTarget(stale)
    assert.equal(entry.target, null)
  }
  const current = target(); entry.publishTarget(current)
  current.contentRect.width = 999
  assert.equal(entry.target.contentRect.width, 50)
})

test('same-page metadata selection revision is refreshed, not misclassified as a page turn', () => {
  const { entry, state, target } = scenario()
  const old = target(); entry.publishTarget(old); entry.beginMove()
  state.selectionId++; entry.update(state)
  assert.equal(entry.phase, 'moving'); assert.equal(entry.target, null)
  entry.publishTarget(old); assert.equal(entry.target, null)
  entry.publishTarget(target()); assert.equal(entry.target.selectionId, state.selectionId)
})

test('navigation, failure and explicit cancellation restore both leaves and reject late completion', () => {
  for (const cause of ['navigation', 'failure', 'cancel']) {
    const { entry, state, target, part } = scenario()
    entry.publishTarget(target()); entry.beginMove()
    if (cause === 'navigation') { state.navigationRevision++; entry.update(state) }
    else if (cause === 'failure') { const failed = target(); failed.failed = true; entry.publishTarget(failed) }
    else entry.cancel()
    entry.arrived(); entry.reveal(); entry.finish(); entry.publishTarget(target())
    assert.equal(entry.phase, 'cancelled'); assert.equal(entry.opacity(part), 1)
    assert.equal(entry.neighborOpacity, 1)
  }
})

test('layout generations reject late measured bounds within an active target', () => {
  const { entry, target } = scenario()
  const current = target(); current.layoutRevision = 4
  entry.publishTarget(current)
  const old = target(); old.contentRect.x = 100
  entry.publishTarget(old)
  assert.equal(entry.target.contentRect.x, 10)
})

test('asset replacement during reveal cannot be completed by the old animation callback', () => {
  const { entry, state, target } = scenario()
  const decoded = target(); decoded.decodedReady = true
  entry.publishTarget(decoded); entry.beginMove(); entry.arrived(); entry.reveal()
  state.frames[0].asset.assetRequestId++
  entry.update(state); entry.finish()
  assert.equal(entry.phase, 'cancelled')
})

test('the same load may deliver after real geometry arrived, without revealing before decode', () => {
  const { entry, state, target } = scenario()
  state.frames[0].asset.assetRequestId = 0
  entry.update(state)
  const beforeDelivery = target()
  entry.publishTarget(beforeDelivery); entry.beginMove(); entry.arrived()
  assert.equal(entry.phase, 'waiting')
  state.frames[0].asset.assetRequestId = state.frames[0].asset.requestId
  entry.update(state)
  assert.equal(entry.phase, 'waiting'); assert.equal(entry.target, null)
  entry.publishTarget(beforeDelivery)
  assert.equal(entry.target, null) // The retired URI-empty leaf cannot republish.
  entry.publishTarget(target()); entry.reveal()
  assert.equal(entry.phase, 'waiting')
  const decoded = target(); decoded.decodedReady = true
  entry.publishTarget(decoded); entry.reveal(); entry.finish()
  assert.equal(entry.phase, 'finished')
})

test('delivery promotion cannot mask another load, slot or navigation during movement', () => {
  for (const cause of ['load', 'slot', 'navigation', 'wrong-asset']) {
    const { entry, state, target } = scenario()
    state.frames[0].asset.assetRequestId = 0
    entry.update(state); entry.publishTarget(target()); entry.beginMove()
    if (cause === 'load') state.frames[0].asset.requestId++
    if (cause === 'slot') state.frames[0].slotId++
    if (cause === 'navigation') state.navigationRevision++
    state.frames[0].asset.assetRequestId = state.frames[0].asset.requestId + (cause === 'wrong-asset' ? 1 : 0)
    entry.update(state); entry.arrived()
    assert.equal(entry.phase, 'cancelled', cause)
    assert.equal(entry.neighborOpacity, 1)
  }
})

test('same-load asset promotion is one-way and a retry cannot reuse its measured target', () => {
  const { entry, state, target } = scenario()
  state.frames[0].asset.assetRequestId = 0
  entry.update(state); entry.publishTarget(target()); entry.beginMove()
  state.frames[0].asset.assetRequestId = state.frames[0].asset.requestId
  entry.update(state); entry.publishTarget(target())
  assert.equal(entry.phase, 'moving')
  state.frames[0].asset.assetRequestId = 0
  entry.update(state)
  assert.equal(entry.phase, 'cancelled')
})

const handoffExports = {}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderRootEntryHandoff.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: handoffExports, require: () => exportsUI })
const { ReaderRootEntryHandoff } = handoffExports
function rootHost() {
  const calls = { flights: 0, targets: 0, reveals: 0, ready: 0, arrival: null }
  const host = {
    authorizeDeparture: () => true,
    setOpeningTarget: () => { calls.targets++; return true },
    startOpening: arrived => { calls.flights++; calls.arrival = arrived },
    revealOriginal: (commit, finished) => { calls.reveals++; commit(); finished() },
    notifyReaderImageReady: () => { calls.ready++ },
  }
  return { calls, host }
}

test('root geometry cancellation retains neighbor fade until the existing arrival callback', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  entry.publishTarget(target()); handoff.sync(entry, true, false, host)
  entry.cancel('image-rect-moved')
  assert.equal(entry.neighborOpacity, 0)
  calls.arrival()
  assert.equal(entry.phase, 'cancelled')
  assert.equal(entry.neighborOpacity, 1)
  assert.equal(calls.ready, 0)
  assert.equal(calls.reveals, 0)
})

test('root reverse releases the companion hold and late arrival cannot reveal content', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  entry.publishTarget(target()); handoff.sync(entry, true, false, host)
  handoff.requestReverse(entry, true, () => true)
  assert.equal(entry.neighborOpacity, 1)
  calls.arrival()
  assert.equal(entry.phase, 'cancelled')
  assert.equal(calls.ready, 0)
  assert.equal(calls.reveals, 0)
})

test('cancellation after root arrival does not hide the already revealed neighbor', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  entry.publishTarget(target()); handoff.sync(entry, true, false, host)
  calls.arrival(); entry.cancel('pager-command')
  assert.equal(entry.neighborOpacity, 1)
})

test('selected-part geometry starts flight before decode and keeps loading input available', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  assert.equal(entry.blocksInput(), true)
  handoff.sync(entry, true, false, host)
  assert.equal(calls.flights, 0)
  entry.publishTarget(target())
  handoff.sync(entry, true, false, host)
  assert.equal(entry.phase, 'moving'); assert.equal(entry.target.contentRect.x, 10)
  assert.equal(entry.blocksInput(), true)
  assert.equal(calls.flights, 1); assert.equal(calls.targets, 1); assert.equal(calls.ready, 0)
  handoff.sync(entry, true, false, host); assert.equal(calls.flights, 1)
  calls.arrival(); assert.equal(entry.phase, 'waiting')
  assert.equal(entry.blocksInput(), false)
  entry.publishTarget(target()); handoff.sync(entry, true, true, host)
  assert.equal(calls.reveals, 0)
  const decoded = target(); decoded.decodedReady = true; entry.publishTarget(decoded)
  handoff.sync(entry, true, true, host)
  assert.equal(entry.phase, 'finished'); assert.equal(calls.reveals, 1); assert.equal(calls.ready, 1)
})

test('host without prepared target retains measured-target departure and rejects failed target admission', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  handoff.sync(entry, true, false, host); assert.equal(calls.flights, 0)
  entry.publishTarget(target()); host.setOpeningTarget = () => false
  handoff.sync(entry, true, false, host)
  assert.equal(entry.phase, 'cancelled'); assert.equal(calls.arrival, null)
})

test('measured opening still requires valid source departure and active route', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  handoff.sync(entry, false, false, host); assert.equal(calls.flights, 0)
  entry.publishTarget(target())
  host.authorizeDeparture = () => false
  handoff.sync(entry, true, false, host)
  assert.equal(entry.phase, 'cancelled'); assert.equal(calls.arrival, null); assert.equal(calls.ready, 0)
})

test('Back during measured opening fences delayed arrival and original reveal', () => {
  const { entry, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  entry.publishTarget(target())
  handoff.sync(entry, true, false, host)
  assert.equal(handoff.requestReverse(entry, true, () => true), true)
  calls.arrival()
  const decoded = target(); decoded.decodedReady = true; entry.publishTarget(decoded)
  handoff.sync(entry, true, true, host)
  assert.equal(entry.phase, 'cancelled'); assert.equal(calls.ready, 0); assert.equal(calls.reveals, 0)
})

test('turning away during online loading cancels entry without accepting a stale original', () => {
  const { entry, state, target } = scenario(); const { calls, host } = rootHost()
  const handoff = new ReaderRootEntryHandoff()
  entry.publishTarget(target()); handoff.sync(entry, true, false, host); calls.arrival()
  assert.equal(entry.blocksInput(), false)
  const late = target(); late.decodedReady = true
  state.navigationRevision++; entry.update(state)
  entry.publishTarget(late); handoff.sync(entry, true, true, host)
  assert.equal(entry.phase, 'cancelled'); assert.equal(calls.ready, 0); assert.equal(calls.reveals, 0)
})
