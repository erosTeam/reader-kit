const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderSession'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
const exportsUI = {}
const closeSource = fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderCloseContext.ets'), 'utf8')
vm.runInNewContext(ts.transpileModule(closeSource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, {
  exports: exportsUI,
  require: name => { assert.equal(name, '@reader-kit/core'); return core },
})
const { ReaderCloseContext } = exportsUI

function frame(key, sourceIndex, fragment, slotId) {
  const part = new core.ReaderDisplayPart(key, `p${sourceIndex}`, sourceIndex, fragment)
  const asset = new core.ReaderSnapshot()
  asset.phase = 'displayed'; asset.kind = 'original'; asset.requestId = slotId + 10
  asset.assetRequestId = slotId + 10; asset.page = new core.ReaderPage(key, `p${sourceIndex}`, sourceIndex)
  asset.page.width = 1200; asset.page.height = 1800
  return new core.ReaderPagedFrame(slotId, part, asset)
}

function snapshot(layout = 'spread') {
  const key = new core.ReaderUnitKey('nh', 'work', 'unit')
  const value = new core.ReaderPagedSnapshot()
  value.unit = new core.ReaderUnit(key, 'Title', 8)
  value.phase = 'ready'; value.policy.layout = layout; value.displayIndex = 2
  value.topologyRevision = 4; value.navigationRevision = 6; value.selectionId = 9
  value.observedSelectionId = 9
  value.observedAnchor = new core.ReaderReadingAnchor(key, 'p3', 3, 0.5, 0, 'whole')
  return { key, value }
}

test('spread close context selects the actually observed frame and freezes request identities', () => {
  const { key, value } = snapshot()
  value.frames = [frame(key, 2, 'whole', 20), frame(key, 3, 'whole', 21)]
  const context = ReaderCloseContext.from(value)
  assert.equal(context.part.sourceIndex, 3)
  assert.equal(context.captureComponentId, 'rkit-part-3-whole')
  assert.equal(context.contentAspectRatio, 2 / 3)
  assert.deepEqual(Array.from(context.displayedSourceIndexes), [2, 3])
  assert.equal(context.matches(value), true)
  value.frames[1].asset.assetRequestId++
  assert.equal(context.assetRequestId, 31)
  assert.equal(context.matches(value), false)
})

test('continuous close context uses the live visible item component, not the selected display index', () => {
  const { key, value } = snapshot('continuous')
  value.visibleDisplayStart = 4; value.visibleDisplayEnd = 5
  value.window = [new core.ReaderPagedItemSnapshot('three', 3, [frame(key, 2, 'whole', 30)]),
    new core.ReaderPagedItemSnapshot('four', 4, [frame(key, 3, 'whole', 31)])]
  const context = ReaderCloseContext.from(value)
  assert.equal(context.captureComponentId, 'rkit-continuous-page-4')
  assert.equal(context.part.sourceIndex, 3)
})

test('unobserved, stale, failed and non-original frames cannot request a return transition', () => {
  const { key, value } = snapshot()
  value.frames = [frame(key, 3, 'whole', 40)]
  value.observedSelectionId = 8
  assert.equal(ReaderCloseContext.from(value), null)
  value.observedSelectionId = 9; value.frames[0].asset.phase = 'failed'
  assert.equal(ReaderCloseContext.from(value), null)
  value.frames[0].asset.phase = 'displayed'; value.frames[0].asset.kind = 'thumbnail'
  assert.equal(ReaderCloseContext.from(value), null)
  value.frames[0].asset.kind = 'original'; value.frames[0].asset.assetRequestId = 0
  assert.equal(ReaderCloseContext.from(value), null)
})

test('surface captures close context before invalidating requests and hands it to the host', () => {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  const start = source.indexOf('  private requestClose(): void {')
  const end = source.indexOf('\n  }', start)
  const body = source.slice(start, end)
  assert.ok(body.indexOf('ReaderCloseContext.fromViewport(this.state,') < body.indexOf('cancelOriginalPreparations()'))
  assert.match(body, /this\.onClose\(context\)/)
  assert.match(source, /@Event onClose: \(context: ReaderCloseContext \| null\) => void/)
})


test('continuous return selects dominant current pixels without changing progress anchor', () => {
  const { key, value } = snapshot('continuous')
  value.visibleDisplayStart = 3; value.visibleDisplayEnd = 5
  value.window = [3,4,5].map(i => new core.ReaderPagedItemSnapshot(String(i), i, [frame(key, i, 'whole', 30+i)]))
  const before = value.observedAnchor
  const areas = { 'rkit-continuous-page-3': 40, 'rkit-continuous-page-4': 1800, 'rkit-continuous-page-5': 800 }
  const context = ReaderCloseContext.from(value, id => areas[id])
  assert.equal(context.part.sourceIndex, 4)
  assert.equal(context.captureComponentId, 'rkit-continuous-page-4')
  assert.equal(value.observedAnchor, before)
  assert.equal(value.observedAnchor.sourceIndexHint, 3)
  assert.equal(context.matches(value), true)
  value.window[1].frames[0].asset.assetRequestId++
  assert.equal(context.matches(value), false)
})

test('continuous close never promotes cached offscreen, failed or unmeasurable images', () => {
  const { key, value } = snapshot('continuous')
  value.visibleDisplayStart = 3; value.visibleDisplayEnd = 4
  value.window = [2,3,4].map(i => new core.ReaderPagedItemSnapshot(String(i), i, [frame(key, i, 'whole', 30+i)]))
  value.window[2].frames[0].asset.phase = 'failed'
  const seen = []
  const context = ReaderCloseContext.from(value, id => { seen.push(id); return 80 })
  assert.equal(context.part.sourceIndex, 3)
  assert.deepEqual(seen, ['rkit-continuous-page-3'])
  for (const area of [0,-1,NaN,Infinity]) assert.equal(ReaderCloseContext.from(value, () => area), null)
  assert.equal(ReaderCloseContext.from(value, () => { throw Error('missing node') }), null)
})

test('continuous close measures viewport intersections, not full cached row sizes', () => {
  const rects = {
    'rkit-continuous-list': { windowOffset: { x: 10, y: 100 }, size: { width: 300, height: 800 } },
    tail: { windowOffset: { x: 10, y: -460 }, size: { width: 300, height: 600 } },
    dominant: { windowOffset: { x: 10, y: 140 }, size: { width: 300, height: 600 } },
    cached: { windowOffset: { x: 10, y: 1000 }, size: { width: 300, height: 900 } },
  }
  const ui = { getComponentUtils: () => ({ getRectangleById: id => rects[id] }) }
  assert.equal(ReaderCloseContext.continuousVisibleArea(ui, 'tail'), 12000)
  assert.equal(ReaderCloseContext.continuousVisibleArea(ui, 'dominant'), 180000)
  assert.equal(ReaderCloseContext.continuousVisibleArea(ui, 'cached'), 0)
})
