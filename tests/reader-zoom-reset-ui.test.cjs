const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const { ReaderViewportTransform } = load('ReaderViewportTransform')

const uiRoot = path.join(__dirname, '../reader-ui/src/main/ets')
const read = file => fs.readFileSync(path.join(uiRoot, `${file}.ets`), 'utf8')

function subject(file, owner, names, globals = {}) {
  const source = read(file).replace(/\bstruct /g, 'class ')
  const tree = ts.createSourceFile(`${file}.ets`, source, ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === owner)
  assert.ok(cls, owner)
  const members = names.map(name => {
    const member = cls.members.find(value => value.name?.getText(tree) === name)
    assert.ok(member, `${owner}.${name}`)
    return member.getText(tree).replace(/^\s*@Monitor\([^\n]+\)\s*/m, '')
  })
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${members.join('\n')} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out, console: { info() {} }, ...globals })
  return out.Subject
}

test('surface emits a fenced reset command only for the currently zoomed unit', () => {
  class ReaderZoomResetCommand {
    constructor(serial, topologyRevision, navigationRevision) {
      Object.assign(this, { serial, topologyRevision, navigationRevision })
    }
  }
  const Surface = subject('ReaderSurface', 'ReaderSurface', ['reportZoomed', 'resetZoom'], { ReaderZoomResetCommand })
  const surface = new Surface()
  const key = { unit: 'u', equals: other => other?.unit === 'u' }
  Object.assign(surface, { active: true, closing: false, chromeDisposed: false, zoomed: false,
    zoomResetSerial: 4, state: { phase: 'ready', topologyRevision: 7, navigationRevision: 9,
      unit: { key } } })

  surface.reportZoomed(true, 6, 9)
  surface.resetZoom(key, 9)
  assert.equal(surface.zoomResetCommand, undefined)
  surface.reportZoomed(true, 7, 9)
  surface.resetZoom(key, 8)
  assert.equal(surface.zoomResetCommand, undefined)
  surface.resetZoom(key, 9)
  assert.deepEqual({ ...surface.zoomResetCommand }, { serial: 5, topologyRevision: 7, navigationRevision: 9 })
})

test('paged viewport consumes each matching reset once and ignores stale context', () => {
  const Viewport = subject('ReaderPagedViewport', 'ReaderPagedViewport', ['onZoomResetCommandChanged'],
    { ReaderViewportTransform })
  const viewport = new Viewport()
  let cancelled = 0
  Object.assign(viewport, { active: true, selected: true, lastZoomResetSerial: 0,
    snapshot: { topologyRevision: 3, navigationRevision: 5 }, zoomState: new ReaderViewportTransform(2, 20, 30),
    pinchAdjusted: true, cancelGesture: () => { cancelled += 1 }, logTransform() {}, onZoomedChange() {} })
  viewport.zoomResetCommand = { serial: 1, topologyRevision: 2, navigationRevision: 5 }
  viewport.onZoomResetCommandChanged()
  assert.equal(viewport.zoomState.scale, 2)
  viewport.zoomResetCommand = { serial: 2, topologyRevision: 3, navigationRevision: 5 }
  viewport.onZoomResetCommandChanged()
  assert.deepEqual(viewport.zoomState, new ReaderViewportTransform())
  assert.equal(viewport.pinchAdjusted, false)
  assert.equal(cancelled, 1)
  viewport.onZoomResetCommandChanged()
  assert.equal(cancelled, 1)
})

test('continuous image reset cancels motion and publishes the unzoomed owner', () => {
  const Image = subject('ReaderContinuousZoomImage', 'ReaderContinuousZoomImage', ['onZoomResetCommandChanged'],
    { ReaderViewportTransform })
  const image = new Image()
  const events = []
  Object.assign(image, { active: true, navigation: 8, lastZoomResetSerial: 0,
    imageTransform: new ReaderViewportTransform(2, 10, 20), pinchAdjusted: true,
    cancelMotion() { events.push('cancel') }, publishLock() { events.push('lock') },
    publishZoomed() { events.push(this.imageTransform.zoomed()) }, log() {} })
  image.zoomResetCommand = { serial: 1, navigationRevision: 7 }
  image.onZoomResetCommandChanged()
  assert.equal(image.imageTransform.scale, 2)
  image.zoomResetCommand = { serial: 2, navigationRevision: 8 }
  image.onZoomResetCommandChanged()
  assert.deepEqual(image.imageTransform, new ReaderViewportTransform())
  assert.deepEqual(events, ['cancel', 'lock', false])
})

test('continuous owner identity includes rotation and reports only its current row', () => {
  const List = subject('ReaderContinuousSurface', 'ReaderContinuousList', ['imageIdentity', 'onImageZoomed'])
  const list = new List()
  const events = []
  const frame = { slotId: 2, asset: { assetRequestId: 4, phase: 'displayed' } }
  Object.assign(list, { createdRevision: 6, zoomedKey: '', zoomedIdentity: '',
    snapshot: { navigationRevision: 5, displayKeys: ['row'], forItem: () => ({ frames: [frame] }) },
    rotates: () => true, onZoomedChange: (...event) => events.push(event) })
  list.onImageZoomed('row', '5:2:4', true)
  assert.deepEqual(events, [])
  list.onImageZoomed('row', '5:2:4:true', true)
  list.onImageZoomed('row', '5:2:4:true', false)
  assert.deepEqual(events, [[true, 6, 5], [false, 6, 5]])
})

test('chrome validates the captured unit before dispatching reset', () => {
  const Chrome = subject('ReaderChrome', 'ReaderChrome', ['selectResetZoom'])
  const chrome = new Chrome()
  const calls = []
  const captured = { unit: 'u', copy() { return { unit: this.unit } } }
  Object.assign(chrome, { active: true, zoomResetAvailable: true, moreShown: true, moreUnit: captured,
    moreNavigation: 3, snapshot: { phase: 'ready', navigationRevision: 3,
      unit: { key: { equals: other => other?.unit === 'u' } } }, onResetZoom: (...args) => calls.push(args) })
  chrome.selectResetZoom()
  assert.equal(chrome.moreShown, false)
  assert.deepEqual(calls, [[{ unit: 'u' }, 3]])
  chrome.moreShown = true
  chrome.snapshot.navigationRevision = 4
  chrome.selectResetZoom()
  assert.equal(calls.length, 1)
})

test('reset state and command remain inside reader-kit viewport composition', () => {
  const surface = read('ReaderSurface')
  const pager = read('ReaderPagerSurface')
  const continuous = read('ReaderContinuousSurface')
  const chrome = read('ReaderChrome')
  assert.match(surface, /@Local private zoomed: boolean = false/)
  assert.match(surface, /new ReaderZoomResetCommand\(this\.zoomResetSerial,[\s\S]*this\.state\.topologyRevision/)
  assert.match(pager, /ReaderPagedViewport\(\{[\s\S]*zoomResetCommand: this\.zoomResetCommand/)
  assert.match(continuous, /ReaderContinuousZoomImage\(\{[\s\S]*zoomResetCommand: this\.zoomResetCommand/)
  assert.match(chrome, /\.id\('rkit-reset-zoom'\)[\s\S]*this\.selectResetZoom\(\)/)
})
