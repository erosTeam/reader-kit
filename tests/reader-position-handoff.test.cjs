const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPositionHandoff.ets'), 'utf8')
const moduleExports = {}
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: moduleExports, require(name) {
  if (name === './ReaderSelectedDrawable') return { ReaderSelectedDrawable: {
    from(value) { return value.frames.length > 0 && value.frames.every(frame =>
      frame.asset.phase === 'displayed' && frame.asset.uri.length > 0) ? {} : null },
  } }
  throw Error(`unexpected runtime import: ${name}`)
} })
const { ReaderPositionHandoff } = moduleExports

function snapshot(displayIndex, navigationRevision, selectionId, phases = ['displayed', 'displayed']) {
  const displayKeys = ['red', 'blue']
  return {
    displayIndex, navigationRevision, selectionId, topologyRevision: 7, displayKeys, kind: 'original',
    forItem(key) { return { key, frames: phases.map((phase, index) => ({ slotId: index + 1,
      asset: { phase, assetRequestId: index + 11, uri: phase === 'displayed' ? 'image://ready' : '',
        notice: phase === 'suppressed' ? { id: 'notice' } : null } })) } },
  }
}

test('position claim retains the original projection across a second seek', () => {
  const first = new ReaderPositionHandoff(1, 0, 7, 10, snapshot(1, 10, 3))
  const second = new ReaderPositionHandoff(2, 1, 7, 10, snapshot(1, 10, 3), first)
  assert.equal(first.oldKey, 'blue')
  assert.equal(second.oldKey, 'blue')
  assert.equal(second.oldProjection, first.oldProjection)
  assert.equal(first.current(1, snapshot(1, 10, 3)), true)
  assert.equal(first.current(2, snapshot(1, 10, 3)), false)
})

test('target must be selected, have newer navigation and have all spread parts drawable', () => {
  const claim = new ReaderPositionHandoff(1, 0, 7, 10, snapshot(1, 10, 3))
  assert.equal(claim.targetDrawable('red', 3, snapshot(1, 10, 3)), false)
  assert.equal(claim.targetDrawable('red', 4, snapshot(0, 10, 4)), false)
  assert.equal(claim.targetDrawable('blue', 4, snapshot(0, 11, 4)), false)
  assert.equal(claim.targetDrawable('red', 4, snapshot(0, 11, 4, ['displayed', 'decoding'])), false)
  assert.equal(claim.targetDrawable('red', 4, snapshot(0, 11, 4)), true)
})

test('cached target readiness defers motion until every original part is decoded or failed', () => {
  const claim = new ReaderPositionHandoff(3, 0, 7, 10, snapshot(1, 10, 3), null, true)
  assert.equal(claim.animated, true)
  assert.equal(claim.targetReadiness(snapshot(1, 10, 3, ['displayed', 'decoding'])), 'pending')
  assert.equal(claim.targetReadiness(snapshot(1, 10, 3)), 'drawable')
  assert.equal(claim.targetReadiness(snapshot(1, 10, 3, ['failed', 'decoding'])), 'pending')
  assert.equal(claim.targetReadiness(snapshot(1, 10, 3, ['failed', 'displayed'])), 'terminal-face')
  assert.equal(claim.targetReadiness(snapshot(1, 10, 3, ['suppressed', 'displayed'])), 'terminal-face')
  const absent = snapshot(1, 10, 3)
  absent.forItem = () => ({ frames: [] })
  assert.equal(claim.targetReadiness(absent), 'pending', 'missing L1 frame cannot expose a native target')
  const stale = snapshot(1, 10, 3)
  stale.topologyRevision += 1
  assert.equal(claim.targetReadiness(stale), 'outside-window')
})

test('L2 visual target requires exact callbacks from every mounted part', () => {
  const claim = new ReaderPositionHandoff(3, 0, 7, 10, snapshot(1, 10, 3), null, true)
  const current = snapshot(1, 10, 3)
  assert.equal(claim.targetNodeReady(current), false)
  assert.equal(claim.targetNodePresented(current, 1, 11, true), false)
  assert.equal(claim.targetNodePresented(current, 2, 12, false), false)
  assert.equal(claim.targetNodePresented(current, 2, 12, true), true)
  assert.equal(claim.targetNodeReady(current), true)
  const replaced = snapshot(1, 10, 3)
  replaced.forItem = key => ({ key, frames: [
    { slotId: 1, asset: { assetRequestId: 11 } },
    { slotId: 2, asset: { assetRequestId: 13 } },
  ] })
  assert.equal(claim.targetNodeReady(replaced), false, 'new request retires old node receipt')
  assert.equal(claim.targetNodePresented(replaced, 2, 12, true), false)
  assert.equal(claim.targetNodePresented(replaced, 2, 13, true), true)
  const stale = snapshot(1, 11, 4)
  assert.equal(claim.targetNodeReady(stale), false, 'navigation change retires visual proof')
  assert.equal(claim.nativeNodePresented(current, 'blue', 1, 11, true), false)
  assert.equal(claim.nativeNodePresented(current, 'red', 1, 11, true), false)
  assert.equal(claim.nativeNodePresented(current, 'red', 2, 12, true), false,
    'cached native receipt is not foreground proof before selection')
  const selected = snapshot(0, 11, 4)
  assert.equal(claim.nativeNodeReady(selected), true, 'all exact native parts and newer selected navigation are required')
  assert.equal(claim.nativeNodeReady(current), false)
  assert.equal(claim.nativeNodeReady(replaced), false, 'replacement request invalidates native receipt')
})

test('terminal handoff needs actual target and native failure-face receipts', () => {
  const claim = new ReaderPositionHandoff(4, 0, 7, 10, snapshot(1, 10, 3), null, true)
  const pending = snapshot(1, 10, 3, ['failed', 'displayed'])
  assert.equal(claim.targetReadiness(pending), 'terminal-face')
  assert.equal(claim.targetNodeReady(pending), false)
  assert.equal(claim.targetTerminalMounted(pending, 1, 11), false)
  assert.equal(claim.targetNodePresented(pending, 2, 12, true), true)
  assert.equal(claim.nativeTerminalMounted(pending, 'red', 1, 11), false)
  assert.equal(claim.nativeNodePresented(pending, 'red', 2, 12, true), false)
  const selected = snapshot(0, 11, 4, ['failed', 'displayed'])
  assert.equal(claim.targetSelected(selected), true)
  assert.equal(claim.nativeNodeReady(selected), true)
  const wrong = snapshot(0, 11, 4, ['suppressed', 'displayed'])
  assert.equal(claim.nativeNodeReady(wrong), true, 'node identity is checked independently from the terminal type')
  wrong.forItem = key => ({ key, frames: [
    { slotId: 1, asset: { phase: 'failed', assetRequestId: 13 } },
    { slotId: 2, asset: { phase: 'displayed', assetRequestId: 12 } },
  ] })
  assert.equal(claim.nativeNodeReady(wrong), false, 'new request invalidates failure-face receipt')
})
