const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadSink() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderPreferenceSink.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: () => ({}) })
  return exports.ReaderPreferenceSink
}

test('preference sink copies adopted policies before crossing the host boundary', () => {
  const ReaderPreferenceSink = loadSink()
  const policy = { copy: () => ({ kind: 'policy-copy' }) }
  const events = []
  const sink = new ReaderPreferenceSink(
    (value, intent) => events.push([value, intent]),
    (enabled, value) => events.push([enabled, value]),
  )

  sink.policyChanged(policy, 'layout')
  sink.cropChanged(true, policy)

  assert.equal(events[0][0].kind, 'policy-copy')
  assert.equal(events[0][1], 'layout')
  assert.equal(events[1][0], true)
  assert.equal(events[1][1].kind, 'policy-copy')
})

test('surface exposes one optional preference output capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param preferenceSink: ReaderPreferenceSink \| null = null/)
  assert.doesNotMatch(source, /@Event onPolicyChanged:/)
  assert.doesNotMatch(source, /@Event onCropChanged:/)
})
