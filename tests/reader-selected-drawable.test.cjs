const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSelectedDrawable.ets'), 'utf8')
const surface = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
const claimExports = {}
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: claimExports })
const { ReaderSelectedDrawable } = claimExports

function snapshot(phases = ['displayed', 'displayed']) {
  const unit = { scope: 'local', work: 'archive', unit: '1',
    copy() { return { ...this } }, equals(other) { return this.scope === other.scope &&
      this.work === other.work && this.unit === other.unit } }
  return {
    phase: 'ready', kind: 'original', unit: { key: unit }, policy: { layout: 'paged' },
    displayIndex: 0, displayCount: 2, displayKeys: ['first', 'second'],
    topologyRevision: 3, navigationRevision: 7, selectionId: 11,
    frames: phases.map((phase, index) => ({
      slotId: 20 + index, part: { sourceIndex: 44 + index, fragment: 'whole' },
      asset: { kind: 'original', phase, uri: phase === 'displayed' ? `file://${index}` : '',
        assetRequestId: 30 + index, visualRevision: 2 },
    })),
  }
}

test('selected drawable requires every original spread part, not one decoded leaf', () => {
  assert.equal(ReaderSelectedDrawable.from(snapshot(['displayed', 'decoding'])), null)
  assert.equal(ReaderSelectedDrawable.from(snapshot(['displayed', 'failed'])), null)
  const ready = ReaderSelectedDrawable.from(snapshot())
  assert.ok(ready)
  assert.equal(ready.partCount(), 2)
  const noUri = snapshot(); noUri.frames[1].asset.uri = ''
  assert.equal(ReaderSelectedDrawable.from(noUri), null)
  const wrongKind = snapshot(); wrongKind.frames[1].asset.kind = 'thumbnail'
  assert.equal(ReaderSelectedDrawable.from(wrongKind), null)
})

test('drawable claim rejects stale position, request, revision and closed source', () => {
  const claim = ReaderSelectedDrawable.from(snapshot())
  assert.equal(claim.current(snapshot()), true)
  const moved = snapshot(); moved.displayIndex = 1
  assert.equal(claim.current(moved), false)
  const selection = snapshot(); selection.selectionId += 1
  assert.equal(claim.current(selection), false)
  const request = snapshot(); request.frames[1].asset.assetRequestId += 1
  assert.equal(claim.current(request), false)
  const revision = snapshot(); revision.frames[0].asset.visualRevision += 1
  assert.equal(claim.current(revision), false)
  const closed = snapshot(); closed.phase = 'closed'
  assert.equal(claim.current(closed), false)
  const continuous = snapshot(); continuous.policy.layout = 'continuous'
  assert.equal(ReaderSelectedDrawable.from(continuous), null)
})

test('surface emits only after a later frame and rechecks current identity', () => {
  const from = surface.indexOf('  private scheduleSelectedDrawable(')
  const to = surface.indexOf('\n  private ', from + 10)
  const code = `class Harness { ${surface.slice(from, to)} }; exports.Harness = Harness`
  const module = { exports: {} }
  vm.runInNewContext(ts.transpileModule(code, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports: module.exports,
    ReaderSelectedDrawable,
    ReaderSelectedDrawableAfterFrame: class { constructor(action) { this.action = action } },
  })
  const harness = new module.exports.Harness()
  const frames = [], signaled = []
  let current = snapshot()
  Object.assign(harness, {
    selectedDrawableSignals: true, active: true, closing: false, chromeDisposed: false,
    drawableScheduledKey: '', drawableSignaledKey: '',
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    session: { snapshot() { return current } }, onSelectedDrawable(claim) { signaled.push(claim) },
  })
  harness.scheduleSelectedDrawable(current)
  assert.equal(signaled.length, 0)
  harness.scheduleSelectedDrawable(current)
  assert.equal(frames.length, 1, 'same identity cannot schedule duplicate callbacks')
  current = snapshot(); current.navigationRevision += 1
  frames.shift()()
  assert.equal(signaled.length, 0, 'late frame cannot reveal an earlier navigation')
  harness.scheduleSelectedDrawable(current)
  frames.shift()()
  assert.equal(signaled.length, 1)
  harness.scheduleSelectedDrawable(current)
  assert.equal(frames.length, 0, 'one selected identity signals once')
})
