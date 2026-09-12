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

function method(name) {
  const tree = ts.createSourceFile('ReaderSurface.ets', source.replace('export struct ReaderSurface', 'export class ReaderSurface'),
    ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(ts.isClassDeclaration)
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
    ...overrides,
  }
}

test('surface publishes only current native-visible original anchors and deduplicates exact repeats', () => {
  const Subject = method('publishObserved')
  const surface = new Subject()
  const events = []
  surface.active = true
  surface.lastObservedSignature = ''
  surface.onObserved = anchor => events.push(anchor)
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

test('surface subscription forwards the observed snapshot after adopting it', () => {
  assert.match(source, /this\.state = state\s+this\.publishObserved\(state\)/)
  assert.match(source, /@Event onObserved: \(anchor: ReaderReadingAnchor\) => void/)
})
