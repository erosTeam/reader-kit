const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'),
  ...load('ReaderPagedSession'), ...load('ReaderInputPort'), ...load('ReaderImageShare'), ...load('ReaderImageSave'), ...load('ReaderAutoRead') }
const uiPath = path.join(__dirname, '../reader-ui/src/main/ets')
function evaluate(source) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, {
    exports, require: name => { assert.equal(name, '@reader-kit/core'); return core },
    ObservedV2: value => value, ComponentV2: value => value,
    Trace() {}, Param() {}, Require() {}, Event() {}, Local() {}, Computed() {}, Monitor: () => () => {},
    console: { info() {} },
  })
  return exports
}
const { ReaderEntryTransition } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderEntryTransition.ets'), 'utf8'))
const source = fs.readFileSync(path.join(uiPath, 'ReaderSurface.ets'), 'utf8')
// Execute actual surface methods, excluding only ArkUI declarative build syntax.
// The session below records calls; no rendering, hardware delivery or UI acceptance is simulated.
const methods = source.slice(0, source.indexOf('\n  build() {'))
  .replace('export struct ReaderSurface {', 'export class ReaderSurface {') + '\n}\n'
const { ReaderSurface } = evaluate(methods)
function scenario(phase = null) {
  const surface = new ReaderSurface()
  surface.active = true; surface.state.phase = 'ready'; surface.state.topologyRevision = 7
  surface.inputTopology = 7; surface.inputLocked = false
  const moves = []; let navigation = 10; let reads = 0
  surface.session = {
    snapshot() { reads++; const state = new core.ReaderPagedSnapshot(); state.navigationRevision = navigation; return state },
    move(intent) { moves.push(intent); navigation++ },
  }
  const part = new core.ReaderDisplayPart(new core.ReaderUnitKey('eh', 'work', 'work'), null, 0)
  if (phase !== null) {
    surface.entryTransition = new ReaderEntryTransition(1, part)
    surface.entryTransition.phase = phase
  }
  const input = new core.ReaderInputPort()
  input.connect(intent => surface.externalMove(intent))
  return { surface, input, moves, reads: () => reads }
}

test('actual externalMove rejects layout before touching the session, including already queued input', () => {
  const value = scenario('moving')
  const queued = () => value.input.move('next')
  value.surface.entryTransition.phase = 'layout'
  assert.equal(queued(), false)
  assert.equal(value.input.move('previous'), false)
  assert.deepEqual(value.moves, []); assert.equal(value.reads(), 0)
  assert.equal(value.surface.entryTransition.phase, 'layout')
})

test('leaving layout restores the existing move path without changing active or replacing the input owner', () => {
  const value = scenario('layout')
  assert.equal(value.input.move('next'), false)
  value.surface.entryTransition.phase = 'moving'
  assert.equal(value.input.move('next'), true)
  assert.equal(value.surface.active, true); assert.deepEqual(value.moves, ['next'])
})

test('null, moving, waiting, revealing and terminal entries retain the existing logical input semantics', () => {
  for (const phase of [null, 'moving', 'waiting', 'revealing', 'finished', 'cancelled']) {
    const value = scenario(phase)
    assert.equal(value.input.move('next'), true, phase)
    assert.equal(value.input.move('previous'), true, phase)
    assert.deepEqual(value.moves, ['next', 'previous'])
  }
  const edge = scenario()
  edge.surface.session.move = intent => edge.moves.push(intent)
  assert.equal(edge.input.move('next'), false)
  assert.deepEqual(edge.moves, ['next'])
})

test('the pre-existing active, session, interaction and topology locks still reject external moves', () => {
  for (const [field, locked] of [['active', false], ['touching', true], ['menuVisible', true],
    ['shareBusy', true], ['informationBusy', true], ['previewIndex', 0], ['inputTopology', 6], ['inputLocked', true]]) {
    const value = scenario('waiting'); value.surface[field] = locked
    assert.equal(value.input.move('next'), false, field)
    assert.deepEqual(value.moves, []); assert.equal(value.reads(), 0)
  }
  const opening = scenario(); opening.surface.state.phase = 'opening'
  assert.equal(opening.input.move('next'), false); assert.deepEqual(opening.moves, [])
})

function chromeScenario() {
  const { surface } = scenario()
  const events = []
  surface.onChromeVisible = visible => events.push(visible)
  surface.session.setViewportActive = () => {}
  surface.session.close = () => {}
  surface.shareController.update = () => {}
  surface.shareController.close = () => {}
  return { surface, events }
}
function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

test('optional automatic advance consumes actual session readiness and Surface interaction gates', async () => {
  const surface = new ReaderSurface(), timers = new Map(); let timerId = 0
  surface.active = true; surface.autoReadAvailable = true; surface.autoReadSeconds = 5
  surface.autoReadController = new core.ReaderAutoReadController(() => surface.externalMove('next'), {
    set(callback, delay) { timers.set(++timerId, {callback, delay}); return timerId },
    clear(id) { timers.delete(id) },
  })
  const key = new core.ReaderUnitKey('source', 'work', 'unit')
  const session = new core.ReaderPagedSession({
    open: async k => new core.ReaderUnit(k, 'Title', 3),
    page: async (unit, index) => new core.ReaderPage(unit.key, `p${index}`, index), adjacent: () => null,
  }, {cancellationMode: 'consumer-only', load: async page => new core.ReaderAsset(`file://${page.sourceIndex}`)})
  surface.session = session
  session.subscribe(state => { surface.state = state; surface.syncAutoRead() })
  await session.open(key); await new Promise(resolve => setImmediate(resolve))
  surface.reportInputLock(false, surface.state.topologyRevision)
  surface.toggleAutoRead(); assert.equal(timers.size, 0, 'URL is not displayed')
  const frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  assert.equal([...timers.values()][0].delay, 5000)
  for (const [field, blocked, normal] of [['shareBusy', true, false], ['saveBusy', true, false],
    ['informationBusy', true, false], ['previewIndex', 0, -1], ['touching', true, false], ['menuVisible', true, false]]) {
    surface[field] = blocked; surface.syncAutoRead(); assert.equal(timers.size, 0, field)
    surface[field] = normal; surface.syncAutoRead(); assert.equal([...timers.values()][0].delay, 5000, field)
  }
  surface.reportInputLock(true, surface.state.topologyRevision); assert.equal(timers.size, 0)
  surface.reportInputLock(false, surface.state.topologyRevision); assert.equal(timers.size, 1)
  surface.entryTransition = new ReaderEntryTransition(1, frame.part)
  surface.entryTransition.phase = 'layout'; surface.onAutoReadEntryChanged(); assert.equal(timers.size, 0)
  surface.entryTransition.phase = 'moving'; surface.onAutoReadEntryChanged(); assert.equal(timers.size, 1)
  surface.entryTransition = null; surface.onAutoReadEntryChanged(); assert.equal(timers.size, 1)
  surface.active = false; surface.onActiveChanged(); assert.equal(timers.size, 0)
  surface.active = true; surface.onActiveChanged(); assert.equal(timers.size, 1)
  const [id, timer] = [...timers][0]; timers.delete(id); timer.callback()
  assert.equal(session.snapshot().displayIndex, 1); assert.equal(timers.size, 0, 'new current image must be displayed')
  surface.requestClose(); assert.equal(surface.autoReadController.isEnabled(), false)
  surface.syncAutoRead(); assert.equal(timers.size, 0)
  session.close(); surface.autoReadController.close()
})
async function flushChrome() { await Promise.resolve(); await Promise.resolve() }

test('null chrome gate preserves synchronous hide/show and preview dismissal', () => {
  const { surface, events } = chromeScenario()
  surface.previewIndex = 3
  surface.toggleChrome()
  assert.equal(surface.chromeVisible, false); assert.equal(surface.previewIndex, -1)
  surface.toggleChrome()
  assert.equal(surface.chromeVisible, true)
  assert.deepEqual(events, [false, true])
})

test('before-show waits for readiness and coalesces pending taps without notifying an uncommitted show', async () => {
  const { surface, events } = chromeScenario(); const gate = deferred()
  let calls = 0, current
  surface.beforeShowChrome = check => { calls++; current = check; return gate.promise }
  surface.toggleChrome(); assert.equal(calls, 0)
  surface.toggleChrome(); surface.toggleChrome(); surface.toggleChrome()
  assert.equal(calls, 1); assert.equal(current(), true)
  assert.equal(surface.chromeVisible, false); assert.deepEqual(events, [false])
  gate.resolve(true); await flushChrome()
  assert.equal(surface.chromeVisible, true); assert.deepEqual(events, [false, true])
  assert.equal(surface.chromeShowPending, false)
})

test('false, rejected and synchronously throwing gates leave chrome hidden and permit retry', async () => {
  for (const outcome of ['false', 'reject', 'throw']) {
    const { surface, events } = chromeScenario()
    surface.toggleChrome()
    surface.beforeShowChrome = () => {
      if (outcome === 'throw') throw new Error('host failure')
      return outcome === 'reject' ? Promise.reject(new Error('host failure')) : Promise.resolve(false)
    }
    surface.toggleChrome(); await flushChrome()
    assert.equal(surface.chromeVisible, false, outcome)
    assert.equal(surface.chromeShowPending, false); assert.deepEqual(events, [false])
    surface.beforeShowChrome = () => Promise.resolve(true)
    surface.toggleChrome(); await flushChrome()
    assert.equal(surface.chromeVisible, true)
  }
})

test('active loss, host closing, disappearance and component close invalidate pending show immediately', async () => {
  for (const reason of ['inactive', 'closing', 'disappear', 'close']) {
    const { surface, events } = chromeScenario(); const gate = deferred()
    let current, closes = 0
    surface.onClose = () => { closes++; assert.equal(current(), false) }
    surface.beforeShowChrome = check => { current = check; return gate.promise }
    surface.toggleChrome(); surface.toggleChrome()
    if (reason === 'inactive') { surface.active = false; surface.onActiveChanged() }
    if (reason === 'closing') { surface.closing = true; surface.onClosingChanged() }
    if (reason === 'disappear') surface.aboutToDisappear()
    if (reason === 'close') surface.requestClose()
    assert.equal(current(), false, reason)
    surface.toggleChrome(); gate.resolve(true); await flushChrome()
    assert.equal(surface.chromeVisible, false, reason); assert.deepEqual(events, [false])
    assert.equal(closes, reason === 'close' ? 1 : 0)
  }
})

test('a stale completion cannot show chrome or clear a newer pending request after reactivation', async () => {
  const { surface, events } = chromeScenario(); const first = deferred(), second = deferred()
  surface.beforeShowChrome = () => first.promise
  surface.toggleChrome(); surface.toggleChrome()
  surface.active = false; surface.onActiveChanged(); surface.active = true
  surface.beforeShowChrome = () => second.promise
  surface.toggleChrome()
  first.resolve(true); await flushChrome()
  assert.equal(surface.chromeVisible, false); assert.equal(surface.chromeShowPending, true)
  second.resolve(true); await flushChrome()
  assert.equal(surface.chromeVisible, true); assert.deepEqual(events, [false, true])
})
