const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadSink() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderObservationSink.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports,
    require: () => ({}),
  })
  return exports.ReaderObservationSink
}

test('observation sink copies values before crossing the host boundary', () => {
  const ReaderObservationSink = loadSink()
  const anchor = { copy: () => ({ kind: 'anchor-copy' }) }
  const position = { copy: () => ({ kind: 'position-copy' }) }
  const received = []
  const sink = new ReaderObservationSink(value => received.push(value), value => received.push(value))

  sink.observeAnchor(anchor)
  sink.observePosition(position)

  assert.deepEqual(received.map(value => value.kind), ['anchor-copy', 'position-copy'])
})

test('surface exposes one optional observation capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param observation: ReaderObservationSink \| null = null/)
  assert.match(source, /this\.observation\?\.observeAnchor\(anchor\)/)
  assert.match(source, /this\.observation\?\.observePosition\(position\)/)
  assert.doesNotMatch(source, /@Event onObserved:/)
  assert.doesNotMatch(source, /@Event onObservedPosition:/)
})
