const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderDisplayMap') }

const surfacePath = path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets')
const source = fs.readFileSync(surfacePath, 'utf8')
const viewportPath = path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagedViewport.ets')
const viewportSource = fs.readFileSync(viewportPath, 'utf8')

function method(name) {
  const tree = ts.createSourceFile('ReaderSurface.ets', source.replace('export struct ReaderSurface', 'export class ReaderSurface'),
    ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderSurface')
  const member = cls.members.find(value => value.name?.getText(tree) === name)
  assert.ok(member, name)
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${member.getText(tree)} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out })
  return out.Subject
}

function state(anchor, overrides = {}) {
  return {
    phase: 'ready',
    unit: { key: anchor.unit },
    observedAnchor: anchor,
    selectionId: 3,
    observedSelectionId: 3,
    observedPosition() { return null },
    ...overrides,
  }
}

test('surface publishes only current native-visible original anchors and deduplicates exact repeats', () => {
  const Subject = method('publishObserved')
  const surface = new Subject()
  const events = []
  surface.active = true
  surface.lastObservedSignature = ''
  surface.lastObservedPositionSignature = ''
  surface.observation = {
    observeAnchor: anchor => events.push(anchor.copy()),
    observePosition: () => {},
  }
  const key = new core.ReaderUnitKey('scope', 'work', 'unit-a')
  const anchor = new core.ReaderReadingAnchor(key, 'page-2', 1, 0.5, 0.25, 'whole')

  surface.publishObserved(state(anchor, { phase: 'catalog' }))
  surface.publishObserved(state(anchor, { observedSelectionId: 2 }))
  surface.publishObserved(state(anchor, { unit: { key: new core.ReaderUnitKey('scope', 'work', 'unit-b') } }))
  surface.active = false
  surface.publishObserved(state(anchor))
  assert.equal(events.length, 0)

  surface.active = true
  surface.publishObserved(state(anchor))
  assert.equal(events.length, 1)
  assert.notEqual(events[0], anchor)
  assert.equal(events[0].pageKey, 'page-2')
  surface.publishObserved(state(anchor))
  assert.equal(events.length, 1)

  const scrolled = new core.ReaderReadingAnchor(key, 'page-2', 1, 0.5, 0.75, 'whole')
  surface.publishObserved(state(scrolled))
  assert.equal(events.length, 2)
  assert.equal(events[1].y, 0.75)
})

test('surface publishes changed decoded coverage even when the reading anchor is unchanged', () => {
  const Subject = method('publishObserved')
  const surface = new Subject()
  const events = []
  surface.active = true
  surface.lastObservedSignature = ''
  surface.lastObservedPositionSignature = ''
  surface.observation = {
    observeAnchor: () => {},
    observePosition: position => events.push(position.displayedSourceIndexes.slice()),
  }
  const key = new core.ReaderUnitKey('scope', 'work', 'unit-a')
  const anchor = new core.ReaderReadingAnchor(key, 'page-2', 1)
  const position = indexes => ({ displayedSourceIndexes: indexes, terminalSourceDisplayed: indexes.includes(2),
    copy() { return this } })

  surface.publishObserved(state(anchor, { observedPosition: () => position([1]) }))
  surface.publishObserved(state(anchor, { observedPosition: () => position([1]) }))
  surface.publishObserved(state(anchor, { observedPosition: () => position([1, 2]) }))
  assert.deepEqual(events, [[1], [1, 2]])
})

test('surface subscription forwards the observed snapshot after adopting it', () => {
  assert.match(source, /this\.state = state\s+this\.publishObserved\(state\)/)
  assert.match(source, /@Param observation: ReaderObservationSink \| null = null/)
})

test('selected paged viewport publishes the anchor original after the displayed snapshot is adopted', () => {
  const tree = ts.createSourceFile('ReaderPagedViewport.ets',
    viewportSource.replace('export struct ReaderPagedViewport', 'export class ReaderPagedViewport'),
    ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderPagedViewport')
  const member = cls.members.find(value => value.name?.getText(tree) === 'reportSelectedVisible')
  assert.ok(member)
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${member.getText(tree)} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out })
  const viewport = new out.Subject()
  const events = []
  viewport.active = true
  viewport.selected = true
  viewport.zoomAnimating = false
  viewport.pinching = false
  viewport.zoomState = { scale: 1 }
  viewport.entryTransition = null
  viewport.onVisible = (...event) => events.push(event)
  viewport.snapshot = {
    phase: 'ready', selectionId: 7,
    anchor: { sourceIndexHint: 2, pageKey: 'page-2' },
    frames: [
      { slotId: 10, part: { sourceIndex: 3, pageKey: 'page-3', fragment: 'whole' },
        asset: { kind: 'original', phase: 'displayed', assetRequestId: 20, page: { key: 'page-3' } } },
      { slotId: 9, part: { sourceIndex: 2, pageKey: 'page-2', fragment: 'whole' },
        asset: { kind: 'original', phase: 'displayed', assetRequestId: 19, page: { key: 'page-2' } } },
    ],
  }
  viewport.reportSelectedVisible()
  assert.deepEqual(events, [[7, 9, 19, 'whole']])

  viewport.snapshot.frames[1].asset.phase = 'decoding'
  viewport.reportSelectedVisible()
  viewport.snapshot.frames[1].asset.phase = 'displayed'
  viewport.zoomState.scale = 2
  viewport.reportSelectedVisible()
  viewport.zoomState.scale = 1
  viewport.entryTransition = { pending: () => true }
  viewport.reportSelectedVisible()
  assert.equal(events.length, 1)
  assert.match(viewportSource, /this\.scheduleSelectedVisible\(\)/)
  assert.match(viewportSource,
    /this\.snapshot\.selectionId !== selection \|\|[\s\S]*this\.snapshot\.navigationRevision !== navigation/)
})
