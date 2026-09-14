const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadPolicy() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderAutoReadPolicy.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.ReaderAutoReadPolicy
}

test('automatic-reading policy keeps host availability and interval separate', () => {
  const ReaderAutoReadPolicy = loadPolicy()
  const policy = new ReaderAutoReadPolicy(true, 9)
  assert.equal(policy.available, true)
  assert.equal(policy.seconds, 9)
  const fallback = new ReaderAutoReadPolicy()
  assert.equal(fallback.available, false)
  assert.equal(fallback.seconds, 3)
})

test('surface exposes one optional automatic-reading policy', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param autoReadPolicy: ReaderAutoReadPolicy \| null = null/)
  assert.match(source, /this\.autoReadPolicy\.seconds/)
  assert.doesNotMatch(source, /@Param autoReadAvailable:/)
  assert.doesNotMatch(source, /@Param autoReadSeconds:/)
})
