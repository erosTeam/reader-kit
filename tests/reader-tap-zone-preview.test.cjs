const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const uiPath = path.join(__dirname, '../reader-ui/src/main/ets')
const regionSource = fs.readFileSync(path.join(uiPath, 'ReaderTapZonePreviewRegion.ets'), 'utf8')
const surfaceSource = fs.readFileSync(path.join(uiPath, 'ReaderSurface.ets'), 'utf8')

function evaluate(source) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, { exports, require: name => {
    if (name === './ReaderTapAction') return {}
    throw new Error(`unexpected import: ${name}`)
  } })
  return exports
}

function method(name) {
  const tree = ts.createSourceFile('ReaderSurface.ets',
    surfaceSource.replace('export struct ReaderSurface', 'export class ReaderSurface'), ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderSurface')
  const member = cls.members.find(value => value.name?.getText(tree) === name)
  assert.ok(member, name)
  const source = member.getText(tree).replace(/^\s*@Monitor\([^\n]+\)\s*/m, '')
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${source} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out })
  return out.Subject
}

test('preview regions accept only finite normalized non-empty interactive cells', () => {
  const { ReaderTapZonePreviewRegion } = evaluate(regionSource)
  assert.equal(new ReaderTapZonePreviewRegion('previous', 0, 0, 1 / 3, 1).valid(), true)
  assert.equal(new ReaderTapZonePreviewRegion('none', 0, 0, 1, 1).valid(), false)
  assert.equal(new ReaderTapZonePreviewRegion('menu', -0.1, 0, 1, 1).valid(), false)
  assert.equal(new ReaderTapZonePreviewRegion('menu', 0, 0, 1.1, 1).valid(), false)
  assert.equal(new ReaderTapZonePreviewRegion('menu', 0.5, 0, 0.5, 1).valid(), false)
  assert.equal(new ReaderTapZonePreviewRegion('menu', 0, Number.NaN, 1, 1).valid(), false)
})

test('a new explicit revision reveals once, hides chrome, and freezes interaction until dismissal', () => {
  const Subject = method('onTapZonePreviewChanged')
  const surface = new Subject()
  const events = []
  Object.assign(surface, {
    tapZonePreviewRevision: 1, tapZonePreviewShownRevision: 0,
    closing: false, chromeDisposed: false, state: { phase: 'ready' }, tapZonePreviewVisible: false,
    validTapZonePreviewRegions: () => [{}], commitChromeVisible: visible => events.push(['chrome', visible]),
    reportInteractionBusy: () => events.push(['busy']), syncAutoRead: () => events.push(['auto']),
  })
  surface.onTapZonePreviewChanged()
  assert.equal(surface.tapZonePreviewShownRevision, 1)
  assert.equal(surface.tapZonePreviewVisible, true)
  assert.deepEqual(events, [['chrome', false], ['busy'], ['auto']])
  surface.onTapZonePreviewChanged()
  assert.equal(events.length, 3)

  const blocked = new Subject()
  Object.assign(blocked, {
    tapZonePreviewRevision: 2, tapZonePreviewShownRevision: 1,
    closing: false, chromeDisposed: false, state: { phase: 'ready' },
    validTapZonePreviewRegions: () => [], commitChromeVisible: () => assert.fail('invalid geometry hid chrome'),
  })
  blocked.onTapZonePreviewChanged()
  assert.equal(blocked.tapZonePreviewShownRevision, 1)
})

test('dismissal is edge-triggered and the surface gates automatic and external movement', () => {
  const Subject = method('dismissTapZonePreview')
  const surface = new Subject()
  const events = []
  Object.assign(surface, { tapZonePreviewVisible: true,
    reportInteractionBusy: () => events.push('busy'), syncAutoRead: () => events.push('auto') })
  surface.dismissTapZonePreview()
  surface.dismissTapZonePreview()
  assert.equal(surface.tapZonePreviewVisible, false)
  assert.deepEqual(events, ['busy', 'auto'])
  assert.match(surfaceSource, /this\.tapZonePreviewVisible \|\| this\.previewIndex >= 0/)
  assert.match(surfaceSource, /this\.menuVisible \|\| this\.tapZonePreviewVisible \|\| this\.shareBusy/)
  assert.match(surfaceSource, /\.id\('rkit-tap-zone-preview'\)/)
})
