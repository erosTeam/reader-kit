const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'),
  ...load('ReaderPagedSession'), ...load('ReaderInputPort'), ...load('ReaderImageShare'), ...load('ReaderImageSave'),
  ...load('ReaderAutoRead'), ...load('ReaderTemporaryVariantOverride') }
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
      if (name === './ReaderZoomResetCommand') return { ReaderZoomResetCommand: class ReaderZoomResetCommand {
        constructor(serial, topologyRevision, navigationRevision) {
          Object.assign(this, { serial, topologyRevision, navigationRevision })
        }
      } }
      if (name === './ReaderSystemBarController') return { ReaderSystemBarController }
      if (name === './ReaderCloseContext') return { ReaderCloseContext }
      if (name === './ReaderVariantPolicy') return { ReaderVariantPolicy }
      if (name === './ReaderCropPolicy') return { ReaderCropPolicy }
      if (name === './ReaderAutoReadPolicy') return { ReaderAutoReadPolicy }
      if (name === '@kit.ArkUI') return { window: { AvoidAreaType: { TYPE_SYSTEM: 0 } }, FrameCallback: class FrameCallback {}, UIUtils: { applySync: action => action() } }
      assert.fail(`unexpected import: ${name}`)
    },
    ObservedV2: value => value, ComponentV2: value => value,
    Builder() {}, Trace() {}, Param() {}, Require() {}, Event() {}, Local() {}, Computed() {}, BuilderParam() {}, Monitor: () => () => {},
    ImageInterpolation: { Low: 'low', Medium: 'medium', High: 'high' },
    Curve: { FastOutSlowIn: 'curve' },
    Color: { Black: '#000000', White: '#FFFFFF' },
    console: { info() {} },
  })
  return exports
}
const { ReaderEntryTransition } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderEntryTransition.ets'), 'utf8'))
const { ReaderCloseContext } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderCloseContext.ets'), 'utf8'))
const { ReaderVariantPolicy } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderVariantPolicy.ets'), 'utf8'))
const { ReaderCropPolicy } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderCropPolicy.ets'), 'utf8'))
const { ReaderAutoReadPolicy } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderAutoReadPolicy.ets'), 'utf8'))
const source = fs.readFileSync(path.join(uiPath, 'ReaderSurface.ets'), 'utf8')
// Execute actual surface methods, excluding only ArkUI declarative build syntax.
// The session below records calls; no rendering, hardware delivery or UI acceptance is simulated.
const methods = source.slice(0, source.indexOf('\n  build() {'))
  .replace('export struct ReaderSurface {', 'export class ReaderSurface {') + '\n}\n'
const { ReaderSystemBarController } = evaluate(fs.readFileSync(path.join(uiPath, 'ReaderSystemBarController.ets'), 'utf8'))
const { ReaderSurface } = evaluate(methods)
ReaderSurface.prototype.getUIContext = () => ({ getComponentUtils() { throw new Error("No viewport in non-rendering test") } })
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

test('image information appends host-owned lines after retained file facts', () => {
  const surface = new ReaderSurface()
  const labels = {
    rkit_unknown: 'unknown', rkit_info_format: 'Format: ', rkit_info_size: 'Size: ',
    rkit_info_current: 'Current: ', rkit_info_dimensions: 'Dimensions: ',
    rkit_info_resampled: 'resampled', rkit_info_original_available: 'Original: available',
  }
  surface.text = name => labels[name] ?? name
  const frame = { part: { sourceIndex: 3 } }
  surface.mediaActions = { imageShare: null, imageSave: null, informationSupplement: (actual, value) => [
      `Enhancement: ${value.variant}`,
      `Source: page-${actual.part.sourceIndex}`,
      '   ',
    ] }
  const value = {
    mimeType: 'image/webp', bytes: 2048, width: 1280, height: 720,
    variant: 'resampled', originalAvailable: true,
  }
  assert.equal(surface.informationText(value, frame), [
    'Format: WEBP', 'Size: 2.0 KB', 'Current: resampled', 'Original: available',
    'Dimensions: 1280 x 720', 'Enhancement: resampled', 'Source: page-3',
  ].join('\n'))
})

test('host crop switch and source revision both reach the retained page', () => {
  const surface = new ReaderSurface(); let refreshes = 0; const applied = []
  surface.session = {
    refreshCrop() { refreshes++ },
    setCropEnabled(value) { applied.push(value) },
  }
  surface.cropPolicy = new ReaderCropPolicy(true, true, 'detector:v2')
  surface.onCropPolicyChanged()
  assert.equal(refreshes, 1)
  assert.equal(applied.at(-1), true)
  // Flipping only the host switch (the in-reader host settings sheet) must still
  // reach the open page; the detector revision is unchanged and needs no refresh.
  surface.cropPolicy = new ReaderCropPolicy(false, true, 'detector:v2')
  surface.onCropPolicyChanged()
  assert.equal(refreshes, 1)
  assert.equal(applied.at(-1), false)
  assert.match(source, /@Param cropPolicy: ReaderCropPolicy \| null = null/)
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
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-a:2000'))
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
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-b:3000'))
  surface.onVariantPolicyChanged()
  await new Promise(resolve => setImmediate(resolve))
  frame = session.snapshot().frames[0]
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true)
  assert.equal(frame.asset.variantIdentity, 'model-b:3000')
  surface.variantPolicy = new ReaderVariantPolicy(); surface.onVariantPolicyChanged()
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
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-a:2000'))
  const calls = []
  surface.session = { selectVariant(...args) { calls.push(args); return Promise.resolve('changed') } }
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.kind = 'thumbnail'
  state.unit = new core.ReaderUnit(new core.ReaderUnitKey('source', 'work', 'unit'), 'Title', 1)
  state.frames = [{ part: { sourceIndex: 0 }, slotId: 7,
    asset: { requestId: 11, assetRequestId: 11, phase: 'displayed', variant: 'default', variantIdentity: '' } }]

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

test('temporary enhancement override survives an operational pause, changes only the current unit, and never writes host preferences', () => {
  const surface = new ReaderSurface(), callbacks = [], cancels = [], preparationCancels = [], selects = [], preferenceWrites = []
  surface.active = true; surface.temporaryVariantActive = true; surface.closing = false; surface.chromeDisposed = false
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-a:2000'))
  surface.temporaryVariantControl = { available: true, changed: enabled => callbacks.push(enabled) }
  surface.preferenceSink = {
    policyChanged: () => preferenceWrites.push('policy'),
    cropChanged: () => preferenceWrites.push('crop'),
  }
  let key = new core.ReaderUnitKey('source', 'work', 'unit-a')
  const page = new core.ReaderPage(key, 'page-a', 0)
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.kind = 'original'; state.unit = new core.ReaderUnit(key, 'Title', 1)
  state.navigationRevision = 7
  state.frames = [{ part: { sourceIndex: 0 }, slotId: 7,
    asset: { requestId: 11, assetRequestId: 12, phase: 'displayed', variant: 'enhanced',
      variantIdentity: 'model-a:2000', page } }]
  surface.state = state
  surface.session = {
    snapshot: () => state,
    cancelRetainedProcessedVariantReplacements: indexes => cancels.push(indexes),
    cancelProcessedVariantPreparations: indexes => preparationCancels.push(Array.from(indexes)),
    selectVariant: (...args) => { selects.push(args); return Promise.resolve('changed') },
    setViewportActive() {},
  }
  // Exercise the real active monitor while keeping unrelated share/save UI
  // presenters out of this state-contract fixture.
  surface.shareController = { update() {} }
  surface.saveController = { update() {} }

  surface.toggleTemporaryVariant()
  let scope = surface.temporaryVariantScope(state)
  assert.equal(surface.temporaryVariantOverride.isDisabled(scope), true)
  assert.deepEqual(cancels.map(indexes => Array.from(indexes)), [[0]])
  assert.deepEqual(callbacks, [false])
  assert.deepEqual(preferenceWrites, [])

  // A host settings sheet pauses operational input by setting active=false; it does not end the Reader route.
  surface.active = false; surface.onActiveChanged()
  assert.equal(surface.temporaryVariantOverride.isDisabled(scope), true)
  surface.active = true; surface.onActiveChanged()

  state.frames[0].asset = { requestId: 13, assetRequestId: 13, phase: 'displayed', variant: 'default',
    variantIdentity: '', page }
  surface.toggleTemporaryVariant()
  assert.deepEqual(callbacks, [false, true])
  assert.equal(selects.length, 1)
  assert.equal(selects[0][4], 'enhanced')
  assert.equal(selects[0][5], 'model-a:2000')
  assert.deepEqual(preferenceWrites, [])

  surface.toggleTemporaryVariant()
  assert.deepEqual(preparationCancels, [[0]])
  state.navigationRevision = 8; surface.syncPreferredVariant(state)
  scope = surface.temporaryVariantScope(state)
  assert.equal(surface.temporaryVariantOverride.isDisabled(scope), false)

  surface.toggleTemporaryVariant()
  key = new core.ReaderUnitKey('source', 'work', 'unit-b')
  state.unit = new core.ReaderUnit(key, 'Title', 1); page.unit = key
  surface.syncPreferredVariant(state)
  scope = surface.temporaryVariantScope(state)
  assert.equal(surface.temporaryVariantOverride.isDisabled(scope), false)

  surface.toggleTemporaryVariant()
  surface.temporaryVariantActive = false; surface.onTemporaryVariantLifecycleChanged()
  assert.equal(surface.temporaryVariantOverride.isDisabled(surface.temporaryVariantScope(state)), false)
})

test('host interaction signal is edge-triggered and clears after the gesture', () => {
  const surface = new ReaderSurface(), events = []
  Object.assign(surface, { active: true, closing: false, chromeDisposed: false, inputLocked: false,
    activitySink: { interactionBusyChanged: busy => events.push(busy) } })
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
  surface.chapterNavigation = {
    busy: false,
    request: (direction, source) => events.push([direction, source.unit]),
  }
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
  surface.chapterNavigation.busy = true
  surface.requestBoundaryChapter('next', 7, 10)
  assert.deepEqual(events, [['next', 'chapter']])
})

function chromeScenario() {
  const { surface } = scenario()
  // The reader entry default is hidden (matching every legacy host). These
  // toggle tests exercise the show/hide state machine from the already-shown
  // state, so request it explicitly instead of relying on the old default.
  surface.chromeVisible = true
  const events = []
  surface.activitySink = { chromeChanged: visible => events.push(visible) }
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
  surface.active = true; surface.autoReadPolicy = new ReaderAutoReadPolicy(true, 5)
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

test('entry chrome follows the host param and defaults hidden like every legacy host', () => {
  // Mount-time default: the product opens hidden, and the param may override it
  // on the first frame for a host-owned QA launch.
  assert.equal(new ReaderSurface().chromeVisible, false, 'product default is hidden')
  assert.equal(new ReaderSurface().initialChromeVisible, false, 'param default is hidden')
  assert.match(source, /this\.chromeVisible = this\.initialChromeVisible/,
    'mount must apply the host request instead of a fixed initial value')
})

test('chrome without a window controller preserves synchronous hide/show and preview dismissal', () => {
  const { surface, events } = chromeScenario()
  surface.previewIndex = 3
  surface.toggleChrome()
  assert.equal(surface.chromeVisible, false); assert.equal(surface.previewIndex, -1)
  surface.toggleChrome()
  assert.equal(surface.chromeVisible, true)
  assert.deepEqual(events, [false, true])
})

test('chrome commits immediately while native window work is unresolved', async () => {
  const { surface, events } = chromeScenario(), native = deferred(), intents = []
  surface.windowPresentation = { presentChrome(visible, fullscreen, dark, current) {
    intents.push({ visible, fullscreen, dark, current }); return native.promise
  } }
  surface.toggleChrome(); surface.toggleChrome()
  assert.equal(surface.chromeVisible, true)
  assert.deepEqual(events, [false, true])
  assert.equal(intents[0].current(), false)
  assert.equal(intents[1].current(), true)
  surface.toggleChrome()
  assert.equal(surface.chromeVisible, false)
  assert.equal(intents[1].current(), false)
  native.resolve(); await flushChrome()
  assert.equal(surface.chromeVisible, false)
})

test('retirement invalidates the native operation without keeping a pending toolbar show', () => {
  for (const reason of ['inactive', 'closing', 'disappear', 'close']) {
    const { surface } = chromeScenario(); let current, closes = 0
    surface.windowPresentation = { presentChrome(_visible, _fullscreen, _dark, check) { current = check; return Promise.resolve() } }
    surface.onClose = () => { closes++; assert.equal(current(), false) }
    surface.toggleChrome(); surface.toggleChrome()
    assert.equal(surface.chromeVisible, true)
    if (reason === 'inactive') { surface.active = false; surface.onActiveChanged() }
    if (reason === 'closing') { surface.closing = true; surface.onClosingChanged() }
    if (reason === 'disappear') surface.aboutToDisappear()
    if (reason === 'close') surface.requestClose()
    assert.equal(current(), false, reason)
    assert.equal(closes, reason === 'close' ? 1 : 0)
  }
})

test('pending spread entry defers both visible variants, resumes once after finish, and not after cancellation', () => {
  const surface = new ReaderSurface()
  surface.active = true; surface.closing = false; surface.chromeDisposed = false
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-a:2000'))
  const key = new core.ReaderUnitKey('source', 'work', 'unit')
  const part = new core.ReaderDisplayPart(key, 'p0', 0)
  const state = new core.ReaderPagedSnapshot()
  state.phase = 'ready'; state.kind = 'original'; state.navigationRevision = 4
  state.unit = new core.ReaderUnit(key, 'Title', 2)
  state.frames = [{ part, slotId: 7,
    asset: { requestId: 11, assetRequestId: 11, page: new core.ReaderPage(key, 'p0', 0),
      phase: 'displayed', variant: 'default', variantIdentity: '' } },
    { part: new core.ReaderDisplayPart(key, 'p1', 1), slotId: 8,
      asset: { requestId: 12, assetRequestId: 12, page: new core.ReaderPage(key, 'p1', 1),
        phase: 'displayed', variant: 'default', variantIdentity: '' } }]
  const calls = []
  surface.session = { snapshot: () => state,
    selectVariant(...args) { calls.push(args); return Promise.resolve('changed') } }
  surface.entryTransition = new ReaderEntryTransition(1, part)
  surface.entryTransition.phase = 'moving'

  surface.syncPreferredVariant(state)
  assert.equal(calls.length, 0)
  assert.equal(surface.variantAttempts.size, 0)

  surface.entryTransition.phase = 'finished'
  surface.onEntryVariantGateChanged()
  assert.equal(calls.length, 2)
  assert.equal(calls[0][0], 7)
  assert.equal(calls[1][0], 8)
  assert.equal(calls[0][4], 'enhanced')
  surface.onEntryVariantGateChanged()
  assert.equal(calls.length, 2)

  surface.entryTransition = new ReaderEntryTransition(2, part)
  surface.entryTransition.phase = 'moving'
  surface.variantPolicy = new ReaderVariantPolicy(new core.ReaderVariantPreference('enhanced', 'model-b:3000'))
  surface.syncPreferredVariant(state)
  surface.entryTransition.cancel('back-reverse-claimed')
  surface.onEntryVariantGateChanged()
  assert.equal(calls.length, 2)
})

test('existing entry phase gate releases crop once on finish, with native animation, and synchronously on cancel', () => {
  for (const phase of ['finished', 'cancelled']) {
    const surface = new ReaderSurface(), events = []
    Object.assign(surface, { entryCropDeferred: true, active: true, closing: false,
      entryTransition: { phase: 'moving' }, session: { setCropPresentationDeferred: v => events.push(['crop', v]), snapshot: () => ({}) },
      getUIContext: () => ({ animateTo: (options, action) => { events.push(['animation', options.duration]); action() } }),
      syncPreferredVariant: () => events.push(['variant']) })
    surface.onEntryVariantGateChanged(); assert.equal(events.length, 0)
    surface.entryTransition.phase = phase; surface.onEntryVariantGateChanged()
    assert.equal(surface.entryCropDeferred, false)
    assert.deepEqual(events, phase === 'finished' ? [['animation',180],['crop',false],['variant']] : [['crop',false]])
    surface.onEntryVariantGateChanged()
    assert.equal(events.filter(e => e[0] === 'crop').length, 1)
  }
})
