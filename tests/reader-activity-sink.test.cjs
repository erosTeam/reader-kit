const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadSink() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderActivitySink.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports })
  return exports.ReaderActivitySink
}

test('activity sink keeps chrome and interaction signals independently optional', () => {
  const ReaderActivitySink = loadSink()
  const events = []
  new ReaderActivitySink(visible => events.push(['chrome', visible])).chromeChanged(false)
  new ReaderActivitySink(null, busy => events.push(['busy', busy])).interactionBusyChanged(true)
  assert.deepEqual(events, [['chrome', false], ['busy', true]])
})

test('surface keeps close independent from passive activity notifications', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Event onClose: \(context: ReaderCloseContext \| null\) => void/)
  assert.match(source, /@Param activitySink: ReaderActivitySink \| null = null/)
  assert.doesNotMatch(source, /@Event onChromeVisible:/)
  assert.doesNotMatch(source, /@Event onInteractionBusy:/)
})
