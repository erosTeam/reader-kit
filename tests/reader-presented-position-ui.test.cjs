const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const root = path.join(__dirname, '../reader-ui/src/main/ets')
const read = name => fs.readFileSync(path.join(root, name), 'utf8')

function methods(file, struct, names) {
  const source = read(file)
  const tree = ts.createSourceFile(file, source.replace(`struct ${struct}`, `class ${struct}`),
    ts.ScriptTarget.Latest, true)
  const subject = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === struct)
  assert.ok(subject, struct)
  const body = names.map(name => {
    const member = subject.members.find(value => value.name?.getText(tree) === name)
    assert.ok(member, name)
    return member.getText(tree)
  }).join('\n')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${body} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.Subject
}

test('one L2 handoff projects the old position without changing the logical session snapshot', () => {
  const Surface = methods('ReaderSurface.ets', 'ReaderSurface',
    ['presentedProjection', 'presentedSourceIndex'])
  const surface = new Surface()
  const unit = { key: { equals(other) { return other === this } } }
  const logical = { topologyRevision: 7, policy: { layout: 'single' }, unit,
    anchor: { sourceIndexHint: 0 } }
  const old = { unit, anchor: { sourceIndexHint: 1 }, frames: [{ part: { sourceIndex: 1 } }] }
  surface.state = logical
  surface.initialUnit = null
  surface.positionHandoff = { topologyRevision: 7, oldProjection: old }
  assert.equal(surface.presentedProjection(), old)
  assert.equal(surface.presentedSourceIndex(), 1)
  assert.equal(surface.state.anchor.sourceIndexHint, 0, 'L1 remains on the logical target')
  surface.positionHandoff = null
  assert.equal(surface.presentedSourceIndex(), 0)
  surface.positionHandoff = { topologyRevision: 6, oldProjection: old }
  assert.equal(surface.presentedProjection(), null, 'stale topology cannot own the UI')
  surface.positionHandoff = { topologyRevision: 7, oldProjection: old }
  surface.state = { ...logical, policy: { layout: 'continuous' } }
  assert.equal(surface.presentedProjection(), null, 'continuous layout has no native handoff')
})

test('page number, slider value, and rail selection follow the same presented position', () => {
  const Chrome = methods('ReaderChrome.ets', 'ReaderChrome', ['count', 'page', 'value'])
  const Rail = methods('ReaderThumbnailRail.ets', 'ReaderThumbnailRail', ['current', 'selected'])
  const logical = { unit: { pageCount: 2 }, anchor: { sourceIndexHint: 0 },
    frames: [{ part: { sourceIndex: 0 } }] }
  const old = { anchor: { sourceIndexHint: 1 }, frames: [{ part: { sourceIndex: 1 } }] }
  const chrome = new Chrome()
  chrome.snapshot = logical
  chrome.presentedSourceIndex = 1
  chrome.preview = -1
  assert.equal(chrome.page(), 2)
  assert.equal(chrome.value(), 2)
  const rail = new Rail()
  rail.snapshot = logical
  rail.presentedSnapshot = old
  assert.equal(rail.current(), 1)
  assert.equal(rail.selected(1), true)
  assert.equal(rail.selected(0), false)
  chrome.presentedSourceIndex = 0
  rail.presentedSnapshot = null
  assert.equal(chrome.value(), 1)
  assert.equal(rail.current(), 0)
  assert.equal(rail.selected(0), true)
})

test('L2 forwards one handoff claim to all visible position consumers, not to navigation intents', () => {
  const surface = read('ReaderSurface.ets')
  const pager = read('ReaderPagerSurface.ets')
  const rail = read('ReaderThumbnailRail.ets')
  assert.match(surface, /onPositionHandoff: \(claim: ReaderPositionHandoff \| null\): void => \{[\s\S]*?this\.positionHandoff = claim[\s\S]*?releasePositionTarget\(previous\.serial\)/)
  assert.match(surface, /onPreparePositionTarget: \(command: ReaderPagerCommand\): boolean =>[\s\S]*?preparePositionTarget\(command\.serial/)
  assert.match(surface, /presentedSnapshot: this\.presentedProjection\(\)/)
  assert.match(surface, /presentedSourceIndex: this\.presentedSourceIndex\(\)/)
  assert.match(surface, /ReaderPageStatus\(\{ value: `\$\{this\.presentedSourceIndex\(\) \+ 1\}/)
  assert.match(pager, /onPositionHandoff\(this\.positionHandoff\)/)
  assert.match(pager, /this\.positionHandoff = null\s+this\.onPositionHandoff\(null\)/)
  assert.match(rail, /this\.onSeek\(index, this\.snapshot\.unit\.key\.copy\(\), this\.snapshot\.navigationRevision\)/)
})
