const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadPolicy() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderCropPolicy.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.ReaderCropPolicy
}

test('crop policy keeps initial state, control availability and detector revision independent', () => {
  const ReaderCropPolicy = loadPolicy()
  const policy = new ReaderCropPolicy(true, false, 'detector:v3')
  assert.equal(policy.enabled, true)
  assert.equal(policy.available, false)
  assert.equal(policy.sourceRevision, 'detector:v3')
  const fallback = new ReaderCropPolicy()
  assert.equal(fallback.enabled, false)
  assert.equal(fallback.available, false)
  assert.equal(fallback.sourceRevision, '')
})

test('surface exposes crop inputs through one optional host policy', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param cropPolicy: ReaderCropPolicy \| null = null/)
  assert.doesNotMatch(source, /@Param cropBorders:/)
  assert.doesNotMatch(source, /@Param cropSourceRevision:/)
  assert.doesNotMatch(source, /@Param cropAvailable:/)
})
