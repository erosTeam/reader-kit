const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const { ReaderSnapshot } = require('./load-core.cjs')('ReaderSession')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderDisplayMap'), ...load('ReaderPagedSession') }
const entryExports = {}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderEntryTransition.ets'), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true } }).outputText, { exports: entryExports, require: () => core, ObservedV2: value => value, Trace: () => {} })
const presentationText = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderImagePlaceholder.ets'), 'utf8')
const presentationSource = presentationText.slice(presentationText.indexOf('export class ReaderImagePresentation'), presentationText.indexOf('/** Metadata'))
const presentationExports = {}
vm.runInNewContext(ts.transpileModule(presentationSource, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, { exports: presentationExports })
const text = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderContinuousSurface.ets'), 'utf8')
const methods = text.slice(text.indexOf('  private originalDrawableIdentity()'), text.indexOf('  private async resolveNoticeAction(frame:'))
const source = `export class Feedback { decodedOriginalIdentity = ''; snapshot; ${methods} }`
const exportsObject = {}
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, { exports: exportsObject, ReaderImagePresentation: presentationExports.ReaderImagePresentation })
function fixture() {
  const value = new exportsObject.Feedback()
  const asset = new ReaderSnapshot()
  asset.assetRequestId = asset.requestId = 7; asset.visualRevision = 2; asset.kind = 'original'; asset.phase = 'decoding'; asset.uri = 'file://current'
  value.snapshot = { frames: [{slotId: 5, part: new core.ReaderDisplayPart(new core.ReaderUnitKey('source', 'unit', 'edition'), 'page4', 3), asset}] }
  return value
}
test('native completion hides only the matching original overlay before stable presentation', () => {
  const value = fixture()
  assert.equal(value.loadingVisible(), true)
  value.originalDecoded('5:7:3:whole:2')
  assert.equal(value.loadingVisible(), false)
  assert.equal(value.snapshot.frames[0].asset.phase, 'decoding')
})
test('reused cell rejects stale request, slot, source, fragment and visual completion', () => {
  for (const identity of ['5:6:3:whole:2', '4:7:3:whole:2', '5:7:2:whole:2', '5:7:3:left:2', '5:7:3:whole:1']) {
    const value = fixture(); value.originalDecoded(identity); assert.equal(value.loadingVisible(), true, identity)
  }
  const value = fixture(); value.originalDecoded('5:7:3:whole:2')
  value.snapshot.frames[0].asset.assetRequestId = 8
  assert.equal(value.loadingVisible(), true)
})
test('thumbnail completion does not dismiss original preparation; terminal states do not load', () => {
  const value = fixture(); const asset = value.snapshot.frames[0].asset
  asset.kind = 'thumbnail'; value.originalDecoded('5:7:3:whole:2'); assert.equal(value.loadingVisible(), true)
  for (const phase of ['idle','asset']) { asset.phase = phase; assert.equal(value.loadingVisible(), true) }
  for (const phase of ['displayed','failed','suppressed']) { asset.phase = phase; assert.equal(value.loadingVisible(), false) }
  value.snapshot.frames = []; assert.equal(value.loadingVisible(), true)
})

test('shared presentation never exposes image pixels together with loading feedback', () => {
  const value = fixture(); const frame = value.snapshot.frames[0]
  for (const phase of ['idle', 'asset', 'decoding', 'displayed', 'failed', 'suppressed']) {
    frame.asset.phase = phase
    for (const decoded of ['', '5:7:3:whole:2', '5:6:3:whole:2']) {
      const presentation = new presentationExports.ReaderImagePresentation(frame, decoded)
      assert.equal(presentation.loading && presentation.pixels, false)
    }
  }
  frame.asset.phase = 'decoding'
  const awaiting = new presentationExports.ReaderImagePresentation(frame, '')
  assert.equal(awaiting.loading, true); assert.equal(awaiting.pixels, false)
  const decoded = new presentationExports.ReaderImagePresentation(frame, '5:7:3:whole:2')
  assert.equal(decoded.loading, false); assert.equal(decoded.pixels, true)
  frame.asset.retainedUri = 'file://retained'; frame.asset.retainedAssetRequestId = 6
  const retained = new presentationExports.ReaderImagePresentation(frame, '')
  assert.equal(retained.loading, false); assert.equal(retained.pixels, true)
})

// A native decode is not yet an exposed original while entry owns opacity zero.
test('decoded original keeps feedback while the real entry still hides its pixels', () => {
  const value = fixture(); const frame = value.snapshot.frames[0]
  Object.assign(value.snapshot, { phase: 'ready', selectionId: 1, topologyRevision: 1, navigationRevision: 1 })
  const entry = new entryExports.ReaderEntryTransition(1, frame.part)
  entry.update(value.snapshot); entry.beginMove(); entry.arrived(); value.entryTransition = entry
  value.originalDecoded('5:7:3:whole:2')
  assert.equal(entry.opacity(frame.part), 0)
  assert.equal(value.loadingVisible(), true, 'decode must not clear feedback above an invisible original')
  frame.asset.phase = 'displayed'
  assert.equal(value.loadingVisible(), true, 'session receipt does not expose the native image')
  const target = new entryExports.ReaderEntryTarget(frame.part)
  Object.assign(target, { selectionId: 1, topologyRevision: 1, navigationRevision: 1,
    slotId: 5, requestId: 7, assetRequestId: 7, decodedReady: true })
  entry.publishTarget(target); entry.reveal()
  assert.equal(entry.opacity(frame.part), 1)
  assert.equal(value.loadingVisible(), false, 'the same reveal commit exposes the original and retires feedback')
})
