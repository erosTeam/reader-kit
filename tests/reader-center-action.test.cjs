const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadCenterAction() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderCenterAction.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: () => ({}) })
  return exports.ReaderCenterAction
}

test('center action retains its label and copies the request unit', () => {
  const ReaderCenterAction = loadCenterAction()
  const calls = []
  const action = new ReaderCenterAction('Chapter 2 / 5', (...values) => calls.push(values))
  action.request({ copy: () => ({ unit: 'copied' }) }, 7)
  assert.equal(action.label, 'Chapter 2 / 5')
  assert.equal(calls[0][0].unit, 'copied')
  assert.equal(calls[0][1], 7)
})
