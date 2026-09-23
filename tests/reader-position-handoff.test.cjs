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
}).outputText, { exports: moduleExports, require() { throw Error('unexpected runtime import') } })
const { ReaderPositionHandoff } = moduleExports

function snapshot(displayIndex, navigationRevision, selectionId, phases = ['displayed', 'displayed']) {
  const displayKeys = ['red', 'blue']
  return {
    displayIndex, navigationRevision, selectionId, topologyRevision: 7, displayKeys,
    forItem(key) { return { key, frames: phases.map(phase => ({ asset: { phase, uri: phase === 'displayed' ? 'image://ready' : '' } })) } },
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
