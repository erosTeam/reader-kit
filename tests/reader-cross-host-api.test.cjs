const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }

test('attested whole-page preview geometry is copied and gated to an uncropped whole original', () => {
  const uiPath = path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagedViewport.ets')
  const source = fs.readFileSync(uiPath, 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source.slice(0, source.indexOf('@ComponentV2')), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: name => name === '@reader-kit/core' ? core :
    name === '@kit.ArkUI' ? { FrameCallback: class {} } : {}, console })
  const unit = new core.ReaderUnitKey('eh', 'work', 'unit')
  const page = new core.ReaderPage(unit, 'page', 0)
  page.previewWidth = 200; page.previewHeight = 300; page.previewCoversWholePage = true
  const asset = new core.ReaderSnapshot()
  asset.kind = 'original'; asset.phase = 'decoding'; asset.page = page
  const frame = new core.ReaderPagedFrame(1, new core.ReaderDisplayPart(unit, 'page', 0), asset)
  assert.equal(page.copy().previewWidth, 200)
  assert.equal(core.readerPagedFrameAspectRatio(frame), 2 / 3)
  assert.equal(exports.ReaderEntryGeometryGate.frame(frame), 'ready')
  frame.crop.left = 0.1
  assert.equal(exports.ReaderEntryGeometryGate.frame(frame), 'unknown')
})

test('real transport progress reaches asset snapshots, but unknown totals do not', async () => {
  const key = new core.ReaderUnitKey('eh', 'work', 'unit')
  const seen = []
  const catalog = {
    async open(k) { return new core.ReaderUnit(k, 'unit', 1) },
    async page(unit) { return new core.ReaderPage(unit.key, 'page', 0) },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only',
    async load(page, _kind, _cancellation, _forceReload, progress) {
      progress(2, 0); progress(4, 10)
      return new core.ReaderAsset(page.key)
    },
  }
  const session = new core.ReaderSession(catalog, assets)
  session.subscribe(snapshot => seen.push(snapshot))
  await session.open(key)
  assert.ok(seen.some(snapshot => snapshot.phase === 'asset' &&
    snapshot.loadProgressLoaded === 4 && snapshot.loadProgressTotal === 10))
  assert.ok(!seen.some(snapshot => snapshot.loadProgressLoaded === 2))
  session.close()
})

test('host presentation callback is observational on both paged and continuous paths', () => {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Event onAssetPresented:/)
  assert.match(source, /this\.reportAssetPresented\(slot, request, success, width, height, false\)/)
  assert.match(source, /this\.reportAssetPresented\(slot, request, success, width, height, true\)/)
  assert.match(source, /catch \(_\) \{[\s\S]*?this\.session\.reportPresentation\(slotId, requestId, success, width, height, paged\)/)
})
