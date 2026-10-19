const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const text = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderContinuousSurface.ets'), 'utf8')
const methods = text.slice(text.indexOf('  private originalDrawableIdentity()'), text.indexOf('  private async resolveNoticeAction(frame:'))
const source = `export class Feedback { decodedOriginalIdentity = ''; snapshot; ${methods} }`
const exportsObject = {}
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, { exports: exportsObject })
function fixture() {
  const value = new exportsObject.Feedback()
  value.snapshot = { frames: [{slotId: 5, part: {sourceIndex: 3, fragment: 'whole'}, asset: {assetRequestId: 7, visualRevision: 2, kind: 'original', phase: 'decoding'}}] }
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
