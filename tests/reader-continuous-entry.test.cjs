const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
const root = path.join(__dirname, '../reader-ui/src/main/ets')
const read = name => fs.readFileSync(path.join(root, name + '.ets'), 'utf8')
function evaluate(source, imports = {}, globals = {}) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true,
  } }).outputText, { exports, require: name => { assert.ok(name in imports, name); return imports[name] },
    ObservedV2: v => v, Trace() {}, Monitor: () => () => {}, console: { info() {} }, ...globals })
  return exports
}
const entry = evaluate(read('ReaderEntryTransition'), { '@reader-kit/core': core })
const { ReaderContinuousEntryPosition: Position } = evaluate(read('ReaderContinuousEntryPosition'))
function methods(file, clsName, names) {
  const source = read(file).replace(/\bstruct /g, 'class ')
  const ast = ts.createSourceFile('test.ts', source, ts.ScriptTarget.Latest, true)
  const cls = ast.statements.find(s => ts.isClassDeclaration(s) && s.name.text === clsName)
  return names.map(name => cls.members.find(m => m.name?.getText(ast) === name).getText(ast)).join('\n')
}
function fixture(width = 400, height = 2400) {
  const unit = new core.ReaderUnitKey('nh', 'qa', 'qa'), page = new core.ReaderPage(unit, 'page', 1)
  page.width = width; page.height = height
  const asset = new core.ReaderSnapshot(); Object.assign(asset, { requestId: 3, assetRequestId: 3, phase: 'displayed', kind: 'original', uri: 'qa', page })
  const frame = new core.ReaderPagedFrame(7, new core.ReaderDisplayPart(unit, 'page', 1), asset)
  const state = new core.ReaderPagedSnapshot()
  Object.assign(state, { phase: 'ready', selectionId: 4, topologyRevision: 5, navigationRevision: 6,
    displayIndex: 1, continuousIndex: 1, continuousPages: [null, frame.asset.page],
    displayKeys: ['other', 'selected'], frames: [frame] })
  state.forItem = key => ({ frames: key === 'selected' ? [frame] : [] })
  const transition = new entry.ReaderEntryTransition(9, frame.part); transition.update(state)
  return { frame, state, transition }
}
const List = evaluate(`export class List { ${methods('ReaderContinuousSurface', 'ReaderContinuousList',
  ['imageTap', 'imageAspectRatio', 'refreshEntryPosition', 'rotates', 'imageIdentity', 'invalidatePosition', 'schedulePosition', 'aboutToDisappear', 'onSnapshotChanged', 'onImageLock', 'onRowGeometry', 'releasePosition'])} }`, {}, {
  ReaderContinuousEntryPosition: Position, clearTimeout() {}, setTimeout: callback => { callback(); return 1 },
  ReaderContinuousAfterLayout: class { constructor(action) { this.action = action } },
  readerPolicyRotatesPage: core.readerPolicyRotatesPage,
  ScrollAlign: { START: 'start' }, LengthMetrics: { vp: x => x },
}).List
function listFixture(ListType = List) {
  const f = fixture(), list = new ListType(), frames = []
  Object.assign(list, { snapshot: f.state, entryTransition: f.transition, entryPosition: null,
    // This harness extracts methods rather than constructing the ArkUI struct.
    // The single-chapter source still needs its List data interface.
    source: { getData: index => f.state.displayKeys[index], update() {} },
    active: true, disposed: false, pendingPosition: false, positionInFlight: false, moving: false,
    positionTarget: -1, positionX: 0.5, positionY: 0, rowGeometry: new Map(), geometryRevision: 0, positionEpoch: 1, viewWidth: 400, positionTimer: 0, measureTimer: 0,
    lockedKey: '', lockedIdentity: '', zoomedKey: '', zoomedIdentity: '', cropRegions: new Map(), lastNavigation: f.state.navigationRevision,
    imageHeight: () => 2400, rowHeight: () => 2400, scheduleMeasure() {},
    scroller: { scrollToIndex() {} }, getUIContext: () => ({ postFrameCallback: value => frames.push(value.action) }),
  })
  f.state.continuousCrop = () => ({ top: 0, bottom: 0 })
  return { ...f, list, frames }
}
test('completed positioning token binds current row, revisions, slot and both asset epochs', () => {
  for (const alter of [f => f.state.selectionId++, f => f.state.topologyRevision++, f => f.state.navigationRevision++,
    f => f.state.continuousIndex = 0, f => f.frame.slotId++, f => f.frame.asset.requestId++, f => f.frame.asset.assetRequestId++]) {
    const f = listFixture(); f.list.refreshEntryPosition(); const token = f.list.entryPosition
    assert.ok(token.isCurrent()); alter(f); assert.equal(token.isCurrent(), false)
  }
})
test('pending/closed/moving positions never grant entry; old post-frame cannot finish a new positioning epoch', () => {
  for (const property of ['pendingPosition', 'positionInFlight', 'disposed', 'moving']) {
    const f = listFixture(); f.list[property] = true; f.list.refreshEntryPosition(); assert.equal(f.list.entryPosition, null)
  }
  const f = listFixture(); f.list.pendingPosition = true; f.list.schedulePosition()
  assert.equal(f.frames.length, 1); f.list.invalidatePosition(); f.frames[0]()
  assert.equal(f.list.pendingPosition, true); assert.equal(f.list.entryPosition, null)
})
test('disappearance invalidates pending token and cancels the hidden entry', () => {
  const f = listFixture(); f.list.refreshEntryPosition(); const token = f.list.entryPosition
  f.list.aboutToDisappear(); assert.equal(token.isCurrent(), false); assert.equal(f.transition.phase, 'cancelled')
})
test('metadata refinement during seek rejects old offset and positions again before granting a token', () => {
  const f = listFixture(), offsets = []; let height = 100
  f.state.kind = 'original'; f.state.anchor = { y: 0.5 }
  f.list.imageHeight = () => height; f.list.rowHeight = () => Math.max(220, height)
  f.list.scroller.scrollToIndex = (_index, _animate, _align, options) => offsets.push(options.extraOffset)
  f.list.pendingPosition = true; f.list.schedulePosition()
  assert.equal(offsets[0], 110); assert.equal(f.list.entryPosition, null)
  height = 400; f.list.positionTimer = 0; f.frames.shift()()
  assert.deepEqual(offsets, [110, 200]); assert.equal(f.list.pendingPosition, true)
  assert.equal(f.list.entryPosition, null); f.frames.shift()()
  assert.equal(f.list.pendingPosition, false); assert.equal(f.list.entryPosition.height, 400)
})
test('initial inactive snapshot waits for onShown rather than cancelling entry; target failure still cancels', () => {
  const f = listFixture(); f.list.active = false; f.list.onSnapshotChanged()
  assert.equal(f.transition.phase, 'layout'); assert.equal(f.list.entryPosition, null)
  f.list.active = true; f.list.onSnapshotChanged(); assert.ok(f.list.entryPosition.isCurrent())
  f.frame.asset.phase = 'failed'; f.list.onSnapshotChanged()
  assert.equal(f.transition.phase, 'cancelled'); assert.equal(f.list.entryPosition.isCurrent(), false)
})
test('only current image zoom lock cancels entry and retires the pending measurement token', () => {
  const f = listFixture(); f.list.refreshEntryPosition(); const token = f.list.entryPosition
  f.list.onImageLock('selected', 'old', true); assert.equal(token.isCurrent(), true)
  f.list.onImageLock('selected', '6:7:3:false', true)
  assert.equal(f.transition.phase, 'cancelled'); assert.equal(token.isCurrent(), false)
  f.list.entryPosition = null; f.list.refreshEntryPosition(); assert.equal(f.list.entryPosition, null)
  const locked = listFixture(); locked.list.lockedKey = 'selected'; locked.list.refreshEntryPosition()
  assert.equal(locked.list.entryPosition, null)
})
const prefix = read('ReaderPagedViewport').split('@ComponentV2')[0]
const gate = evaluate(prefix, { '@reader-kit/core': core, './ReaderEntryTransition': entry,
  '@kit.ArkUI': { FrameCallback: class {} },
}).ReaderEntryGeometryGate
const Image = evaluate(`export class Image { ${methods('ReaderPagedViewport', 'ReaderPagedImage',
  ['publishEntryTarget', 'measureEntryTarget', 'entryLeafId', 'entryContentId'])} }`, {}, {
  ReaderEntryGeometryGate: gate, ...entry,
  ReaderEntryLayoutRevision: { next: n => n + 1 },
  ReaderEntryAfterLayout: class { constructor(action) { this.action = action } },
}).Image
function imageFixture(width = 400, height = 2400) {
  const f = fixture(width, height), callbacks = [], image = new Image()
  let current = true
  const position = new Position(1, f.state, f.frame, 400, height, f.transition, () => current)
  const rectangles = {
    image: { windowOffset: { x: 0, y: -300 }, size: { width: 400, height } },
    content: { windowOffset: { x: 0, y: -300 }, size: { width: 400, height } },
    viewport: { windowOffset: { x: 0, y: 100 }, size: { width: 400, height: 700 } },
  }
  Object.assign(image, { frame: f.frame, slotId: 7, assetRequestId: 3, selectionId: 4,
    topologyRevision: 5, navigationRevision: 6, active: false, continuousEntry: position,
    entryTransition: f.transition, entryMounted: true, decoded: true, decodedWidth: width, decodedHeight: height,
    renderedFragment: 'whole', entryContentLaidOut: true, entryLeafLaidOut: true,
    entryMeasurement: null, entryLayoutRevision: 0, measuredEntryId: -1, measuredEntryRect: null, reportInvalidDecodedMetrics: () => false,
    getUIContext: () => ({ postFrameCallback: v => callbacks.push(v.action), px2vp: x => x, vp2px: x => x,
      getComponentUtils: () => ({ getRectangleById: id => id.startsWith('rkit-entry-image-') ? rectangles.image :
        id.startsWith('rkit-entry-content-') ? rectangles.content :
        id === 'rkit-continuous-list' || id === 'rkit-reading-surface' ? rectangles.viewport :
        { windowOffset: { x: 0, y: 0 }, size: { width: 0, height: 0 } } }) }),
  })
  return { ...f, image, position, callbacks, rectangles, retire: () => { current = false } }
}
test('ordinary reading and retired entries do not enqueue entry geometry work on each image update', () => {
  for (const phase of ['absent', 'finished', 'cancelled']) {
    const f = imageFixture()
    if (phase === 'absent') f.image.entryTransition = null
    else f.transition.phase = phase
    // These are calls from the real image's layout, decode and frame monitors.
    for (let i = 0; i < 100; i++) f.image.publishEntryTarget(i % 2 === 0)
    assert.equal(f.callbacks.length, 0, phase)
  }
})

test('host-owned preview may be absent: leaf measurement preserves long Image bounds and uses the Reader viewport clip', () => {
  const f = imageFixture(); f.image.publishEntryTarget(); assert.equal(f.transition.target, null)
  f.callbacks.shift()(); const t = f.transition.target
  assert.equal(t.contentRect.height, 2400); assert.equal(t.contentRect.y, -300)
  assert.equal(t.clipRect.height, 700); assert.equal(t.clipRect.y, 100); assert.equal(t.decodedReady, true)
})
test('captured old position callback and removed leaf cannot publish or activate hidden content', () => {
  for (const change of [f => f.retire(), f => f.image.continuousEntry = null, f => f.image.entryMounted = false]) {
    const f = imageFixture(); f.image.publishEntryTarget(); change(f); f.callbacks.shift()()
    assert.equal(f.transition.target, null); assert.equal(f.transition.phase, 'layout')
  }
})
test('unknown original dimensions wait; decoded zero cancels; row bounds cannot replace Image bounds', () => {
  const f = imageFixture(); f.frame.asset.page.width = 0; f.image.decoded = false
  f.image.publishEntryTarget(); f.callbacks.shift()(); assert.equal(f.transition.target, null)
  f.frame.asset.page.width = 400; f.image.decoded = true
  f.image.publishEntryTarget(); f.callbacks.shift()(); assert.equal(f.transition.target.contentRect.height, 2400)
  const zero = imageFixture(); zero.image.decodedHeight = 0
  zero.image.publishEntryTarget(); zero.callbacks.shift()(); assert.equal(zero.transition.phase, 'cancelled')
  const mismatch = imageFixture(); mismatch.rectangles.content.size.height = 2600
  mismatch.image.publishEntryTarget(); mismatch.callbacks.shift()(); assert.equal(mismatch.transition.target, null)
})
test('paged default still rejects out-of-viewport geometry and does not get continuous clip allowance', () => {
  const f = imageFixture(); Object.assign(f.image, { continuousEntry: null, active: true, entryLayoutWidth: 400, entryLayoutHeight: 2400 })
  f.image.publishEntryTarget(); f.callbacks.shift()(); assert.equal(f.transition.phase, 'cancelled'); assert.equal(f.transition.target, null)
})

test('terminal backgrounds reuse single-pointer travel filtering and active input gates', () => {
  const TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 }
  const { ReaderTapSequence } = evaluate(read('ReaderTapSequence'), {}, { TouchType })
  const { ReaderTapArbiter, ReaderTapPoint } = evaluate(read('ReaderTapArbiter'), {}, { setTimeout, clearTimeout })
  const Cell = evaluate(`export class Cell { ${methods('ReaderContinuousSurface',
    'ReaderContinuousCell', ['terminalTap', 'terminalIdentity'])} }`, {}, { ReaderTapPoint }).Cell
  const cell = new Cell(), calls = [], sequence = new ReaderTapSequence()
  Object.assign(cell, { active: true, interactionAllowed: true,
    snapshot: { navigationRevision: 3, displayIndex: 0, frames: [] },
    doubleTapEnabled: false, doubleTapIntervalMs: 300,
    terminalTapSequence: sequence, onTap: (x, y) => calls.push([x, y]) })
  cell.terminalTapArbiter = new ReaderTapArbiter(point => cell.onTap(point.windowX, point.windowY), () => {})
  const event = { tapLocation: { x: 150, y: 60, windowX: 150, windowY: 60 } }
  const touch = (type, x, count = 1) => sequence.touch({ type,
    touches: Array.from({ length: count }, () => ({ x, y: 0 })), changedTouches: [{ x, y: 0 }] })
  touch(TouchType.Down, 0); cell.terminalTap(event)
  assert.deepEqual(calls, [[150, 60]])
  touch(TouchType.Move, 9); cell.terminalTap(event)
  touch(TouchType.Down, 0, 2); cell.terminalTap(event)
  touch(TouchType.Down, 0); touch(TouchType.Cancel, 0); cell.terminalTap(event)
  assert.equal(calls.length, 1)
  touch(TouchType.Down, 0)
  cell.active = false; cell.terminalTap(event)
  cell.active = true; cell.interactionAllowed = false; cell.terminalTap(event)
  cell.interactionAllowed = true
  cell.terminalTap(); cell.terminalTap({ tapLocation: { windowX: NaN, windowY: 0 } })
  assert.equal(calls.length, 1)
  cell.terminalTap(event); assert.deepEqual(calls, [[150, 60], [150, 60]])
})

test('continuous geometry can publish decoded dimensions before exposing pixels', () => {
  const Native = evaluate(`export class Native { ${methods('ReaderPagedViewport', 'ReaderPagedImage',
    ['completed', 'schedulePresentation'])} }`, {}, {
    ReaderEntryGeometryGate: gate,
    ReaderEntryAfterLayout: class { constructor(action) { this.action = action } },
  }).Native
  for (const [align, priorWidth, priorHeight, expected] of [
    [true, 0, 0, ['presented']],
    [true, 600, 900, ['pixels', 'presented']],
    [false, 0, 0, ['pixels', 'presented']],
  ]) {
    const f = fixture(), events = [], callbacks = [], image = new Native()
    f.frame.asset.page.width = priorWidth; f.frame.asset.page.height = priorHeight
    Object.assign(image, { frame: f.frame, slotId: 7, assetRequestId: 3, entryMounted: true,
      alignGeometryBeforeVisible: align, decoded: false, decodedRequestId: 0, scheduledPresentationRequestId: 0,
      scheduledPresentationGeometryIdentity: '', drawableIdentity: () => 'same',
      originalGeometryIdentity: () => 'layout', originalGeometryReady: () => true,
      scheduleNativeStability() {}, reportInvalidDecodedMetrics() {}, publishEntryTarget() {}, reportVisible() {},
      onDecodedOriginal: () => events.push('pixels'), onPresented: () => events.push('presented'),
      getUIContext: () => ({ postFrameCallback: value => callbacks.push(value.action) }) })
    image.completed(400, 600)
    callbacks.shift()()
    assert.deepEqual(events, expected)
    if (align && priorWidth === 0) {
      // Real 197 recording: Core's dimensions were published in this callback,
      // while the cell still used its placeholder layout. Wait for that actual
      // metadata/layout update, rather than exposing pixels in the same callback.
      f.frame.asset.page.width = 400; f.frame.asset.page.height = 600
      image.originalGeometryIdentity = () => 'applied-layout'
      image.schedulePresentation(); callbacks.shift()()
      assert.deepEqual(events, ['presented', 'presented', 'pixels'])
    }
  }
})

test('continuous original uses attested whole-page preview geometry until native dimensions arrive', () => {
  const f = listFixture(), page = f.frame.asset.page
  f.state.kind = 'original'; f.state.pageMetadata = [page]
  f.state.policy = new core.ReaderDisplayPolicy()
  f.state.continuousCrop = () => ({ left: 0, top: 0, right: 0, bottom: 0 })
  page.width = 0; page.height = 0
  page.previewWidth = 690; page.previewHeight = 934; page.previewCoversWholePage = true
  assert.equal(f.list.imageAspectRatio(page.sourceIndex), 690 / 934)
  page.width = 800; page.height = 1200
  assert.equal(f.list.imageAspectRatio(page.sourceIndex), 800 / 1200)
  page.width = 0; page.height = 0; page.previewCoversWholePage = false
  assert.equal(f.list.imageAspectRatio(page.sourceIndex), 0.75)
  page.previewCoversWholePage = true
  f.state.continuousCrop = () => ({ left: 0.1, top: 0, right: 0, bottom: 0 })
  assert.equal(f.list.imageAspectRatio(page.sourceIndex), 0.75)
})

test('native pixel rounding retains the committed target while later real movement still cancels', () => {
  const f = imageFixture(); f.image.publishEntryTarget(); f.callbacks.shift()()
  const original = f.transition.target.contentRect.copy()
  f.transition.phase = 'waiting'
  f.rectangles.image.windowOffset.y += 1; f.rectangles.content.windowOffset.y += 1
  f.image.publishEntryTarget(); f.callbacks.shift()()
  assert.equal(f.transition.phase, 'waiting')
  assert.equal(f.transition.target.contentRect.y, original.y)
  f.rectangles.image.windowOffset.y += .1; f.rectangles.content.windowOffset.y += .1
  f.image.publishEntryTarget(); f.callbacks.shift()()
  assert.equal(f.transition.phase, 'cancelled')
})

test('continuous measured container can authorize flight while the original URI is still loading', () => {
  const f = imageFixture(400, 600)
  f.frame.asset.uri = ''; f.frame.asset.phase = 'asset'; f.image.decoded = false
  f.image.entryLeafLaidOut = false
  f.rectangles.content.windowOffset.y = 100
  f.image.publishEntryTarget(); f.callbacks.shift()()
  assert.equal(f.transition.phase, 'layout')
  assert.equal(f.transition.target.geometryReady, true)
  assert.equal(f.transition.target.decodedReady, false)
})

test('continuous waiting permits current loading-page taps but motion and stale topology do not', () => {
  const f = listFixture(), actions = []
  f.frame.asset.phase = 'asset'
  Object.assign(f.list, { fullyVisible: true, createdRevision: f.state.topologyRevision,
    getUIContext: () => ({ px2vp: x => x, getComponentUtils: () => ({ getRectangleById: () =>
      ({ windowOffset: { x: 0, y: 0 }, size: { width: 400, height: 800 } }) }) }),
    onTap: () => { actions.push('menu'); return 'menu' } })
  f.transition.phase = 'moving'; f.list.imageTap('selected', 200, 400)
  assert.equal(actions.length, 0)
  f.transition.phase = 'waiting'; f.list.imageTap('selected', 200, 400)
  assert.deepEqual(actions, ['menu'])
  f.list.createdRevision--; f.list.imageTap('selected', 200, 400)
  assert.equal(actions.length, 1)
})

test('plain tap remains available during loading without enabling image zoom', () => {
  const Zoom = evaluate(`export class Zoom { ${methods('ReaderContinuousZoomImage',
    'ReaderContinuousZoomImage', ['canTap', 'canInteract'])} }`).Zoom
  const zoom = new Zoom()
  Object.assign(zoom, { active: true, interactionAllowed: true, componentWidth: 400,
    frame: { asset: { phase: 'asset' } } })
  assert.equal(zoom.canTap(), true); assert.equal(zoom.canInteract(), false)
  zoom.frame.asset.phase = 'displayed'; assert.equal(zoom.canInteract(), true)
  zoom.interactionAllowed = false; assert.equal(zoom.canTap(), false)
})

// Native regression 072: an earlier visible row can receive dimensions after
// the requested row has already completed its first positioning frame.
test('ordinary chapter entry keeps its requested row when preceding geometry arrives late', () => {
  const f = listFixture(), positions = []
  f.list.entryTransition = null
  f.list.scroller.scrollToIndex = index => positions.push(index)
  f.list.pendingPosition = true
  f.list.schedulePosition()
  f.frames.shift()()
  assert.deepEqual(positions, [1])
  // A range observation may include the preceding row while the selected last
  // row is shorter than the viewport; that observation is not a new user seek.
  f.state.displayIndex = 0; f.state.continuousIndex = 0
  const prior = new core.ReaderPage(f.frame.part.unit, 'earlier', 0)
  prior.width = 400; prior.height = 1800
  f.state.pageMetadata = [prior]
  f.list.positionTimer = 0
  f.list.onSnapshotChanged()
  f.list.onRowGeometry('other', 1800)
  assert.deepEqual(positions, [1, 1], 'late preceding layout must refine the original navigation target')
})

test('real user takeover prevents late row geometry from pulling navigation back', () => {
  const f = listFixture(), positions = []
  f.list.entryTransition = null
  f.list.scroller.scrollToIndex = index => positions.push(index)
  f.list.schedulePosition(); f.frames.shift()()
  f.list.positionTimer = 0
  f.list.releasePosition()
  f.list.onRowGeometry('other', 1800)
  assert.deepEqual(positions, [1])
})
test('repeated unchanged row geometry does not create another seek', () => {
  const f = listFixture(), positions = []
  f.list.entryTransition = null
  f.list.scroller.scrollToIndex = index => positions.push(index)
  f.list.schedulePosition(); f.frames.shift()(); f.list.positionTimer = 0
  f.list.onRowGeometry('other', 1800); f.frames.shift()(); f.list.positionTimer = 0
  f.list.onRowGeometry('other', 1800)
  assert.deepEqual(positions, [1, 1])
})


// Keep native-frame and timer queues separate: cancellation can race with a
// callback already delivered to the event loop, so even a cancelled callback is replayed.
function queuedListFixture() {
  const timers = [], cancelled = new Set()
  const QueuedList = evaluate(`export class List { ${methods('ReaderContinuousSurface', 'ReaderContinuousList',
    ['imageTap', 'imageAspectRatio', 'refreshEntryPosition', 'rotates', 'imageIdentity', 'invalidatePosition',
      'schedulePosition', 'aboutToDisappear', 'onSnapshotChanged', 'onImageLock', 'onRowGeometry', 'releasePosition'])} }`, {}, {
    ReaderContinuousEntryPosition: Position,
    clearTimeout: id => cancelled.add(id),
    setTimeout: callback => { timers.push(callback); return timers.length },
    ReaderContinuousAfterLayout: class { constructor(action) { this.action = action } },
    readerPolicyRotatesPage: core.readerPolicyRotatesPage,
    ScrollAlign: { START: 'start' }, LengthMetrics: { vp: x => x },
  }).List
  return { ...listFixture(QueuedList), timers, cancelled }
}
for (const stage of ['timer', 'postFrame']) for (const cause of ['user takeover', 'target failure']) {
  test(`queued ${stage} cannot restore chapter positioning after ${cause}`, () => {
    const f = queuedListFixture(), positions = []
    f.list.entryTransition = null
    f.list.scroller.scrollToIndex = index => positions.push(index)
    f.list.pendingPosition = true
    f.list.schedulePosition(); f.timers[0](); f.frames.shift()()
    assert.deepEqual(positions, [1])
    f.list.onRowGeometry('other', 1800)
    const timerId = f.list.positionTimer
    assert.ok(timerId > 0)
    if (stage === 'postFrame') f.timers[timerId - 1]()
    const beforeRelease = positions.length
    if (cause === 'user takeover') f.list.releasePosition()
    else {
      f.frame.asset.phase = 'failed'
      f.list.onSnapshotChanged()
    }
    assert.equal(f.list.positionTarget, -1)
    assert.equal(f.list.pendingPosition, false)
    assert.equal(f.list.positionInFlight, false)
    if (stage === 'timer') {
      assert.equal(f.cancelled.has(timerId), true)
      // Deliberately invoke the stale callback even though clearTimeout was called.
      f.timers[timerId - 1]()
    } else f.frames.shift()()
    assert.equal(positions.length, beforeRelease)
    assert.equal(f.list.positionTarget, -1)
    assert.equal(f.list.pendingPosition, false)
    assert.equal(f.list.positionInFlight, false)
    f.list.onRowGeometry('other', 1900)
    assert.equal(positions.length, beforeRelease)
    assert.equal(f.list.positionTimer, 0)
  })
}
test('geometry behind the target does not invalidate an in-flight positioning frame', () => {
  const f = queuedListFixture()
  f.list.entryTransition = null
  f.state.displayKeys.push('later')
  f.list.pendingPosition = true
  f.list.schedulePosition(); f.timers[0]()
  const revision = f.list.geometryRevision
  f.list.onRowGeometry('later', 1800)
  assert.equal(f.list.geometryRevision, revision)
  f.frames.shift()()
  assert.equal(f.list.pendingPosition, false)
  assert.equal(f.timers.length, 1)
})

// Execute the production area callback, including position-only native updates.
function continuousAreaFixture(transform) {
  const source = read('ReaderContinuousZoomImage').replace(/\bstruct /g, 'class ')
  const ast = ts.createSourceFile('area.ts', source, ts.ScriptTarget.Latest, true)
  let callback
  const visit = node => {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === 'onAreaChange') callback = node.arguments[0]
    ts.forEachChild(node, visit)
  }
  visit(ast); assert.ok(callback)
  const viewport = load('ReaderViewportTransform')
  const AreaZoom = evaluate(`export class AreaZoom {
    ${methods('ReaderContinuousZoomImage', 'ReaderContinuousZoomImage', ['geometry'])}
    updateArea(old, area) { (${callback.getText(ast)})(old, area) }
  }`, {}, { ReaderViewportGeometry: viewport.ReaderViewportGeometry }).AreaZoom
  const zoom = new AreaZoom(), calls = { cancel: 0, lock: 0, changed: 0, log: 0 }
  Object.assign(zoom, {
    componentWidth: 400, componentHeight: 800, measuredImageHeight: 800, imageHeight: 800,
    rotateClockwise: false, imageTransform: transform,
    frame: { asset: { kind: 'original', page: { width: 800, height: 1600 } },
      crop: { region: () => ({ width: 1, height: 1 }) }, part: {} },
    cancelMotion: () => calls.cancel++, publishLock: () => calls.lock++,
    publishZoomed: () => calls.changed++, log: () => calls.log++,
  })
  return { zoom, calls }
}
test('same-size continuous area movement preserves transform identity and does not republish layout state', () => {
  const { ReaderViewportTransform: Transform } = load('ReaderViewportTransform')
  for (const before of [new Transform(), new Transform(2, 10, 20)]) {
    const f = continuousAreaFixture(before)
    f.zoom.updateArea({ width: 400, height: 800, position: { x: 0, y: 0 } },
      { width: 400, height: 800, position: { x: 0, y: -180 } })
    assert.equal(f.zoom.imageTransform, before, 'List movement is not a new image geometry or transform')
    assert.deepEqual(f.calls, { cancel: 0, lock: 0, changed: 0, log: 0 })
  }
})


test('same-size area movement does not interrupt an active pinch or zoom animation', () => {
  const { ReaderViewportTransform: Transform } = load('ReaderViewportTransform')
  for (const state of ['pinching', 'animating']) {
    const before = new Transform(2, 10, 20), f = continuousAreaFixture(before)
    f.zoom[state] = true
    f.zoom.cancelMotion = () => { f.calls.cancel++; f.zoom.pinching = false; f.zoom.animating = false }
    f.zoom.updateArea({ width: 400, height: 800 }, { width: 400, height: 800, position: { x: 0, y: 350 } })
    assert.equal(f.zoom[state], true)
    assert.equal(f.zoom.imageTransform, before)
    assert.deepEqual(f.calls, { cancel: 0, lock: 0, changed: 0, log: 0 })
  }
})
for (const kind of ['width', 'container height', 'image height']) {
  test(`actual continuous ${kind} change preserves zoom through the production reflow callback`, () => {
    const { ReaderViewportTransform: Transform, ReaderViewportGeometry: Geometry } = load('ReaderViewportTransform')
    const before = new Transform(2, 110, 230), f = continuousAreaFixture(before)
    const previous = f.zoom.geometry()
    let width = 400, height = 800, imageHeight = 800
    if (kind === 'width') { width = 600; height = 1200; imageHeight = 1200 }
    if (kind === 'container height') height = 1000
    if (kind === 'image height') imageHeight = 1200
    f.zoom.imageHeight = imageHeight
    f.zoom.updateArea({ width: 400, height: 800 }, { width, height })
    const expected = before.reflow(previous, new Geometry(width, height, width, imageHeight, 800 / width))
    assert.equal(f.zoom.imageTransform.scale, expected.scale)
    assert.equal(f.zoom.imageTransform.x, expected.x)
    assert.equal(f.zoom.imageTransform.y, expected.y)
    assert.deepEqual(f.calls, { cancel: 1, lock: 1, changed: 1, log: 1 })
    assert.equal(f.zoom.componentWidth, width)
    assert.equal(f.zoom.componentHeight, height)
    assert.equal(f.zoom.measuredImageHeight, imageHeight)
    const settled = f.zoom.imageTransform
    f.zoom.updateArea({ width, height }, { width, height, position: { x: 0, y: -20 } })
    assert.equal(f.zoom.imageTransform, settled)
    assert.equal(f.calls.cancel, 1)
  })
}

// A short last row cannot reach the viewport top. Its explicit seek target
// still owns page selection while a host sheet temporarily suspends input.
test('opening and closing a host sheet preserves explicit continuous page selection', () => {
  const Measure = evaluate(`export class Measure { ${methods('ReaderContinuousSurface',
    'ReaderContinuousList', ['measuredPosition', 'scheduleMeasure'])} }`, {}, {
    setTimeout: callback => { callback(); return 1 },
  }).Measure
  const f = listFixture(), observed = []
  f.list.entryTransition = null
  Object.assign(f.list, { fullyVisible: true, viewHeight: 800,
    createdRevision: f.state.topologyRevision, nativeReady: new Map(),
    measuredPosition: Measure.prototype.measuredPosition,
    scheduleMeasure: Measure.prototype.scheduleMeasure,
    onRange: (_start, _end, _topology, _navigation, position) => observed.push(position),
  })
  f.list.scroller.getItemIndex = (_x, y) => y <= 1 ? 0 : 1
  f.list.scroller.getItemRect = index => index === 1
    ? { y: 200, height: 600 } : { y: -1600, height: 1800 }
  f.list.imageHeight = index => f.list.scroller.getItemRect(index).height
  f.list.rowHeight = f.list.imageHeight
  f.list.pendingPosition = true
  f.list.schedulePosition(); f.frames.shift()(); f.list.positionTimer = 0
  assert.equal(observed.at(-1), 1)
  f.list.active = false; f.list.onSnapshotChanged()
  f.list.measureTimer = 0
  f.list.active = true; f.list.onSnapshotChanged()
  assert.equal(observed.at(-1), 1, 'sheet dismissal must not replace the explicit last page with its visible predecessor')
  // Actual scrolling must still take over from the retained command. Move
  // the last page below the viewport; merely dropping the command while that
  // whole page remains visible is not evidence of a different reading position.
  f.list.scroller.getItemRect = index => index === 1
    ? { y: 300, height: 600 } : { y: -1500, height: 1800 }
  f.list.releasePosition(); f.list.measureTimer = 0; f.list.scheduleMeasure()
  assert.equal(observed.at(-1), 0)
})

// Use the actual LazyForEach -> Cell binding rather than a copy of its projection.
function continuousCellBinding() {
  const source = read('ReaderContinuousSurface').replace(/\bstruct /g, 'class ')
  const ast = ts.createSourceFile('cell.ts', source, ts.ScriptTarget.Latest, true)
  let binding
  const visit = node => {
    if (ts.isCallExpression(node) && node.expression.getText(ast) === 'ReaderContinuousCell') {
      binding = node.arguments[0].properties.find(p => p.name?.getText(ast) === 'snapshot').initializer.getText(ast)
    }
    ts.forEachChild(node, visit)
  }
  visit(ast); assert.ok(binding)
  const modulePath = path.join(root, 'ReaderContinuousCellSnapshot.ets')
  const Cache = fs.existsSync(modulePath)
    ? evaluate(read('ReaderContinuousCellSnapshot'), { '@reader-kit/core': core }).ReaderContinuousCellSnapshots : null
  const Bound = evaluate(`export class Bound { project(key) { return ${binding} } }`).Bound
  const value = new Bound(); value.cellSnapshots = Cache === null ? null : new Cache()
  return value
}
function continuousCellState() {
  const f = fixture(800, 1600), state = f.state
  state.unit = new core.ReaderUnit(f.frame.part.unit, 'book', 2)
  state.displayKeys = ['other', 'selected']; state.displayCount = 2
  state.pageMetadata = [f.frame.asset.page.copy()]
  state.window = [new core.ReaderPagedItemSnapshot('selected', 1, [f.frame])]
  delete state.forItem
  return state
}
function copyContinuousCellState(previous) {
  const next = Object.assign(new core.ReaderPagedSnapshot(), previous)
  next.window = previous.window.map(item => new core.ReaderPagedItemSnapshot(item.key, item.index,
    item.frames.map(frame => {
      const result = new core.ReaderPagedFrame(frame.slotId, frame.part, frame.asset, frame.crop)
      result.cropPending = frame.cropPending; return result
    })))
  return next
}
test('an unrelated selection snapshot preserves the settled original Cell input reference', () => {
  const bound = continuousCellBinding(); bound.snapshot = continuousCellState()
  const original = bound.project('selected')
  bound.snapshot = copyContinuousCellState(bound.snapshot)
  bound.snapshot.selectionId++; bound.snapshot.displayIndex = 0
  bound.snapshot.visibleDisplayStart = 0; bound.snapshot.visibleDisplayEnd = 1
  assert.equal(bound.project('selected'), original)
})
test('loading, replacing and failed frames always reach the Cell with current bytes and request epoch', () => {
  for (const prepare of [f => { f.asset.phase = 'asset' }, f => { f.asset.phase = 'decoding' },
    f => { f.asset.phase = 'failed' }, f => { f.asset.requestId++ },
    f => { f.asset.retainedUri = 'prior'; f.asset.retainedAssetRequestId = 2 }, f => { f.cropPending = true }]) {
    const bound = continuousCellBinding(); bound.snapshot = continuousCellState()
    prepare(bound.snapshot.window[0].frames[0]); const before = bound.project('selected')
    bound.snapshot = copyContinuousCellState(bound.snapshot)
    bound.snapshot.window[0].frames[0].asset.loadProgressLoaded = 100
    const after = bound.project('selected'); assert.notEqual(after, before)
    assert.equal(after.frames[0].asset.loadProgressLoaded, 100)
  }
})
test('a changed settled image identity, geometry, crop or navigation never reuses the prior Cell input', () => {
  for (const change of [s => { s.navigationRevision++ }, s => { s.topologyRevision++ },
    s => { s.window[0].frames[0].slotId++ }, s => { s.window[0].frames[0].asset.uri = 'fresh' },
    s => { const a = s.window[0].frames[0].asset; a.requestId++; a.assetRequestId++ },
    s => { s.window[0].frames[0].asset.visualRevision++ }, s => { s.window[0].frames[0].asset.variantIdentity = 'processed' },
    s => { s.window[0].frames[0].crop.left = 0.1 }, s => { s.window[0].frames[0].asset.page.height++ },
    s => { s.window[0].frames[0].asset.page.previewWidth++ }]) {
    const bound = continuousCellBinding(); bound.snapshot = continuousCellState(); const before = bound.project('selected')
    bound.snapshot = copyContinuousCellState(bound.snapshot); change(bound.snapshot)
    assert.notEqual(bound.project('selected'), before)
  }
})
test('an evicted Cell drops its original frame, and a later window cannot revive the cached image input', () => {
  const bound = continuousCellBinding(); bound.snapshot = continuousCellState(); const before = bound.project('selected')
  const restored = copyContinuousCellState(bound.snapshot)
  bound.snapshot = copyContinuousCellState(bound.snapshot); bound.snapshot.window = []
  assert.equal(bound.project('selected').frames.length, 0)
  bound.snapshot = restored; assert.notEqual(bound.project('selected'), before)
})
test('a neighboring original update cannot replace this settled Cell input', () => {
  const bound = continuousCellBinding(); bound.snapshot = continuousCellState()
  const other = new core.ReaderPagedFrame(99, bound.snapshot.window[0].frames[0].part,
    bound.snapshot.window[0].frames[0].asset)
  bound.snapshot.window.push(new core.ReaderPagedItemSnapshot('other', 0, [other]))
  const selected = bound.project('selected'), neighbor = bound.project('other')
  bound.snapshot = copyContinuousCellState(bound.snapshot)
  bound.snapshot.window[1].frames[0].asset.uri = 'neighbor-new-original'
  assert.equal(bound.project('selected'), selected)
  assert.notEqual(bound.project('other'), neighbor)
})
test('a pending entry retains the uncached frame path even when the original is displayed', () => {
  const bound = continuousCellBinding(); bound.snapshot = continuousCellState()
  bound.entryTransition = { pending: () => true }
  const before = bound.project('selected')
  bound.snapshot = copyContinuousCellState(bound.snapshot)
  assert.notEqual(bound.project('selected'), before)
})


test('continuous entry token uses the global row while preserving its real source-page identity', () => {
  const f = fixture()
  f.state.continuousIndex = 2
  f.state.displayKeys = ['preceding-chapter', 'other', 'selected']
  const token = new Position(1, f.state, f.frame, 400, 2400, f.transition, () => true)
  assert.equal(token.key, 'selected')
  assert.equal(token.matches(f.state), true)
  // Insertion above this row changes its List index without changing the image.
  f.state.displayKeys.unshift('earlier-chapter'); f.state.continuousIndex++
  assert.equal(token.matches(f.state), true)
  f.state.continuousIndex--
  assert.equal(token.matches(f.state), false)
})


test('webtoon observed position follows measured page ends, including a short last chapter', () => {
  const Visible = evaluate(`export class Visible { ${methods('ReaderContinuousSurface',
    'ReaderContinuousList', ['measuredPosition'])} }`).Visible
  const value = new Visible()
  const rects = [{ y: -400, height: 600 }, { y: 200, height: 600 }]
  Object.assign(value, { viewHeight: 800, imageHeight: index => rects[index].height,
    scroller: { getItemRect: index => rects[index] } })
  assert.equal(value.measuredPosition(0, 1), 1, 'the last page actually fits, even while the preceding page peeks above it')
  rects[1].height = 1000
  assert.equal(value.measuredPosition(0, 1), 0, 'an incomplete next page cannot displace the current page')
  rects[0] = { y: -100, height: 1400 }
  assert.equal(value.measuredPosition(0, 0), 0, 'a tall current page remains selected while reading within it')
})
