const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadHostSettings() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderHostSettings.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.ReaderHostSettings
}

test('host settings capability forwards one explicit request', () => {
  const ReaderHostSettings = loadHostSettings()
  let calls = 0
  const settings = new ReaderHostSettings(() => { calls += 1 })
  settings.request()
  assert.equal(calls, 1)
})

test('surface derives settings availability from one optional capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param hostSettings: ReaderHostSettings \| null = null/)
  assert.match(source, /hostSettingsAvailable: this\.hostSettings !== null/)
  assert.match(source, /this\.hostSettings\?\.request\(\)/)
  assert.doesNotMatch(source, /@Param hostSettingsAvailable:/)
  assert.doesNotMatch(source, /@Event onHostSettings:/)
})
