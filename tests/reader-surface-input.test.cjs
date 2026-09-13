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
    exports, require: name => {
      if (name === '@reader-kit/core') return core
      if (name === './ReaderPagerSurface') return { ReaderPagerCommand: class ReaderPagerCommand {
        constructor(serial, targetIndex, topologyRevision, navigationRevision) {
          Object.assign(this, { serial, targetIndex, topologyRevision, navigationRevision })
        }
      } }
      assert.fail(`unexpected import: ${name}`)
    },
    ObservedV2: value => value, ComponentV2: value => value,
    Trace() {}, Param() {}, Require() {}, Event() {}, Local() {}, Computed() {}, Monitor: () => () => {},
    ImageInterpolation: { Low: 'low', Medium: 'medium', High: 'high' },
    Color: { Black: '#000000', White: '#FFFFFF' },
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
    cancelOriginalPreparations() {},
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

test('enabled page-turn animation emits one adjacent native pager command before session selection', () => {
  const value = scenario()
  value.surface.pageTurnAnimation = true
  value.surface.state.displayIndex = 1
  value.surface.state.displayCount = 3
  value.surface.state.navigationRevision = 10
  value.surface.session.snapshot = () => value.surface.state

  assert.equal(value.input.move('next'), true)
  assert.deepEqual(value.moves, [])
  assert.equal(value.surface.pagerCommand.serial, 1)
  assert.equal(value.surface.pagerCommand.targetIndex, 2)
  assert.equal(value.surface.pagerCommand.topologyRevision, 7)
  assert.equal(value.surface.pagerCommand.navigationRevision, 10)

  value.surface.state.displayIndex = 0
  assert.equal(value.input.move('previous'), false)
  assert.equal(value.surface.pagerCommand.serial, 1)
})

test('disabled animation and continuous reading retain direct session-owned movement', () => {
  for (const [enabled, layout] of [[false, 'single'], [true, 'continuous']]) {
    const value = scenario()
    value.surface.pageTurnAnimation = enabled
    value.surface.state.policy.layout = layout
    value.surface.state.displayIndex = 1
    value.surface.state.displayCount = 3
    assert.equal(value.input.move('next'), true)
    assert.deepEqual(value.moves, ['next'])
    assert.equal(value.surface.pagerCommand, null)
  }
})

test('preferred host variant follows exact processing identity and returns to default', async () => {
  const surface = new ReaderSurface()
  surface.active = true; surface.closing = false; surface.chromeDisposed = false
  surface.preferredVariant = 'enhanced'; surface.preferredVariantIdentity = 'model-a:2000'
  const key = new core.ReaderUnitKey('source', 'work', 'unit')
  const calls = []
  const session = new core.ReaderPagedSession({
    open: async k => new core.ReaderUnit(k, 'Title', 2),
    page: async (unit, index) => new core.ReaderPage(unit.key, `p${index}`, index), adjacent: () => null,
  }, { cancellationMode: 'consumer-only', async load(page) { return new core.ReaderAsset(`default-${page.sourceIndex}`) },
    async prepareVariant(page, variant, identity) { calls.push(identity); return { page, variant, identity,
      async load() { return new core.ReaderAsset(`${variant}-${identity}`) } } },
  })
  surface.session = session
  session.setViewportActive(true)
  session.subscribe(state => { surface.state = state; surface.syncPreferredVariant(state) })
  await session.open(key); await new Promise(resolve => setImmediate(resolve))
  let frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  await new Promise(resolve => setImmediate(resolve))
  frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  assert.equal(frame.asset.variant, 'enhanced')
  assert.equal(frame.asset.variantIdentity, 'model-a:2000')
  surface.preferredVariantIdentity = 'model-b:3000'; surface.onPreferredVariantChanged()
  await new Promise(resolve => setImmediate(resolve))
  frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  assert.equal(frame.asset.variantIdentity, 'model-b:3000')
  surface.preferredVariant = 'default'; surface.preferredVariantIdentity = ''; surface.onPreferredVariantChanged()
  await new Promise(resolve => setImmediate(resolve))
  frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  assert.equal(frame.asset.variant, 'default')
  assert.deepEqual(calls, ['model-a:2000', 'model-b:3000'])
  session.close()
})

test('preferred host variant waits for the original asset instead of consuming its attempt on a thumbnail', () => {
  const surface = new ReaderSurface()
  surface.active = true; surface.closing = false; surface.chromeDisposed = false
  surface.preferredVariant = 'enhanced'; surface.preferredVariantIdentity = 'model-a:2000'
  const calls = []
  surface.session = { selectVariant(...args) { calls.push(args); return Promise.resolve('changed') } }
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.kind = 'thumbnail'
  state.unit = new core.ReaderUnit(new core.ReaderUnitKey('source', 'work', 'unit'), 'Title', 1)
  state.frames = [{ part: { sourceIndex: 0 }, slotId: 7,
    asset: { requestId: 11, phase: 'displayed', variant: 'default', variantIdentity: '' } }]

  surface.syncPreferredVariant(state)
  assert.equal(calls.length, 0)
  assert.equal(surface.variantAttempts.size, 0)

  state.kind = 'original'
  surface.syncPreferredVariant(state)
  assert.equal(calls.length, 1)
  assert.equal(calls[0][0], 7)
  assert.equal(calls[0][1], 11)
  assert.equal(calls[0][4], 'enhanced')
  assert.equal(calls[0][5], 'model-a:2000')
})

test('host interaction signal is edge-triggered and clears after the gesture', () => {
  const surface = new ReaderSurface(), events = []
  Object.assign(surface, { active: true, closing: false, chromeDisposed: false, inputLocked: false,
    onInteractionBusy: busy => events.push(busy) })
  surface.reportInteractionBusy()
  surface.touching = true; surface.reportInteractionBusy(); surface.reportInteractionBusy()
  surface.touching = false; surface.reportInteractionBusy()
  surface.inputLocked = true; surface.reportInteractionBusy()
  surface.active = false; surface.reportInteractionBusy()
  assert.deepEqual(events, [true, false, true, false])
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

test('unit boundary intent is accepted only for a current available adjacent unit', () => {
  const { surface } = scenario()
  const key = new core.ReaderUnitKey('source', 'work', 'chapter')
  const events = []
  surface.chapterNavigationAvailable = true
  surface.onChapter = (direction, source) => events.push([direction, source.unit])
  surface.session.snapshot = () => {
    const state = new core.ReaderPagedSnapshot()
    state.phase = 'ready'; state.topologyRevision = 7; state.navigationRevision = 10
    state.unit = new core.ReaderUnit(key, 'Chapter', 3)
    state.canPreviousUnit = true; state.canNextUnit = true
    return state
  }
  surface.requestBoundaryChapter('next', 7, 10)
  assert.deepEqual(events, [['next', 'chapter']])
  surface.requestBoundaryChapter('previous', 6, 10)
  surface.requestBoundaryChapter('previous', 7, 9)
  surface.session.snapshot = () => {
    const state = new core.ReaderPagedSnapshot()
    state.phase = 'ready'; state.topologyRevision = 7; state.navigationRevision = 10
    state.unit = new core.ReaderUnit(key, 'Chapter', 3)
    state.canPreviousUnit = false; state.canNextUnit = true
    return state
  }
  surface.requestBoundaryChapter('previous', 7, 10)
  assert.deepEqual(events, [['next', 'chapter']])
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
