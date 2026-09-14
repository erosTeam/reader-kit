const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadExternalOpen() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderExternalOpen.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: () => ({}) })
  return exports.ReaderExternalOpen
}

test('external open capability copies the current unit before host dispatch', () => {
  const ReaderExternalOpen = loadExternalOpen()
  const received = []
  const action = new ReaderExternalOpen(source => received.push(source))
  action.request({ copy: () => ({ unit: 'copied' }) })
  assert.equal(received.length, 1)
  assert.equal(received[0].unit, 'copied')
})

test('surface derives external-open availability from one optional capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param externalOpen: ReaderExternalOpen \| null = null/)
  assert.match(source, /externalOpenAvailable: this\.externalOpen !== null/)
  assert.match(source, /this\.externalOpen\?\.request\(source\)/)
  assert.doesNotMatch(source, /@Param externalOpenAvailable:/)
  assert.doesNotMatch(source, /@Event onExternalOpen:/)
})
