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
    displayIndex: 1, displayKeys: ['other', 'selected'], frames: [frame] })
  state.forItem = key => ({ frames: key === 'selected' ? [frame] : [] })
  const transition = new entry.ReaderEntryTransition(9, frame.part); transition.update(state)
  return { frame, state, transition }
}
const List = evaluate(`export class List { ${methods('ReaderContinuousSurface', 'ReaderContinuousList',
  ['refreshEntryPosition', 'invalidatePosition', 'schedulePosition', 'aboutToDisappear', 'onSnapshotChanged', 'onImageLock'])} }`, {}, {
  ReaderContinuousEntryPosition: Position, clearTimeout() {}, setTimeout: callback => { callback(); return 1 },
  ReaderContinuousAfterLayout: class { constructor(action) { this.action = action } },
  ScrollAlign: { START: 'start' }, LengthMetrics: { vp: x => x },
}).List
function listFixture() {
  const f = fixture(), list = new List(), frames = []
  Object.assign(list, { snapshot: f.state, entryTransition: f.transition, entryPosition: null,
    active: true, disposed: false, pendingPosition: false, positionInFlight: false, moving: false,
    positionEpoch: 1, viewWidth: 400, positionTimer: 0, measureTimer: 0,
    lockedKey: '', lockedIdentity: '', cropRegions: new Map(), lastNavigation: f.state.navigationRevision,
    imageHeight: () => 2400, rowHeight: () => 2400, scheduleMeasure() {},
    scroller: { scrollToIndex() {} }, getUIContext: () => ({ postFrameCallback: value => frames.push(value.action) }),
  })
  f.state.cropForPage = () => ({ top: 0, bottom: 0 })
  return { ...f, list, frames }
}
test('completed positioning token binds current row, revisions, slot and both asset epochs', () => {
  for (const alter of [f => f.state.selectionId++, f => f.state.topologyRevision++, f => f.state.navigationRevision++,
    f => f.state.displayIndex = 0, f => f.frame.slotId++, f => f.frame.asset.requestId++, f => f.frame.asset.assetRequestId++]) {
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
  f.list.onImageLock('selected', '6:7:3', true)
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
    entryLayoutRevision: 0, measuredEntryId: -1, measuredEntryRect: null, reportInvalidDecodedMetrics: () => false,
    getUIContext: () => ({ postFrameCallback: v => callbacks.push(v.action), px2vp: x => x, vp2px: x => x,
      getComponentUtils: () => ({ getRectangleById: id => id.startsWith('rkit-entry-image-') ? rectangles.image :
        id.startsWith('rkit-entry-content-') ? rectangles.content : rectangles.viewport }) }),
  })
  return { ...f, image, position, callbacks, rectangles, retire: () => { current = false } }
}
test('actual leaf measurement preserves full long Image bounds and publishes an independent viewport clip', () => {
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
  f.image.publishEntryTarget(); assert.equal(f.transition.phase, 'cancelled'); assert.equal(f.transition.target, null)
})
