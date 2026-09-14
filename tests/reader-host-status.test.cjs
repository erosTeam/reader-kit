const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadHostStatus() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderHostStatus.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.ReaderHostStatus
}

test('host status keeps passive text and busy presentation in one value', () => {
  const ReaderHostStatus = loadHostStatus()
  const status = new ReaderHostStatus('Processing page', true)
  assert.equal(status.text, 'Processing page')
  assert.equal(status.busy, true)
})

test('surface uses one optional status value instead of independent visibility fields', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param hostStatus: ReaderHostStatus \| null = null/)
  assert.doesNotMatch(source, /@Param hostStatusVisible:/)
  assert.doesNotMatch(source, /@Param hostStatusText:/)
  assert.doesNotMatch(source, /@Param hostStatusBusy:/)
})
