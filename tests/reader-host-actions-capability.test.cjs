const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadHostActions() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderHostActions.ets'), 'utf8')
  const exports = {}
  class ReaderHostAction {
    constructor(id, label, enabled = true, checked = false, busy = false) {
      Object.assign(this, { id, label, enabled, checked, busy })
    }
  }
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports,
    require: value => value.includes('ReaderHostAction') ? { ReaderHostAction } : {},
  })
  return { ReaderHostActions: exports.ReaderHostActions, ReaderHostAction }
}

test('host actions freeze display values and copy the request unit', () => {
  const { ReaderHostActions, ReaderHostAction } = loadHostActions()
  const source = [new ReaderHostAction('translate', 'Translate', true, true, false)]
  const calls = []
  const capability = new ReaderHostActions(source, (...values) => calls.push(values))
  source[0].label = 'Changed'
  const first = capability.items()
  first[0].label = 'Mutated'
  assert.equal(capability.items()[0].label, 'Translate')
  capability.request('translate', { copy: () => ({ unit: 'copied' }) }, 4, 2)
  assert.equal(calls[0][1].unit, 'copied')
  assert.deepEqual(calls[0].slice(2), [4, 2])
})

test('surface exposes action values and dispatch through one optional capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param hostActions: ReaderHostActions \| null = null/)
  assert.match(source, /hostActions: this\.hostActions\?\.items\(\) \?\? \[\]/)
  assert.match(source, /this\.hostActions\?\.request\(id, source, navigation, sourceIndex\)/)
  assert.doesNotMatch(source, /@Event onHostAction:/)
})
