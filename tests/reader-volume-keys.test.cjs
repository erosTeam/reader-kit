const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderVolumeKeys.ets'), 'utf8')
function fixture() {
  const registrations = [], removed = [], moves = [], exports = {}
  const inputConsumer = {
    on: (_name, spec, callback) => registrations.push({ spec, callback }),
    off: (_name, callback) => removed.push(callback),
  }
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
  } }).outputText, { exports, console: { info() {}, warn() {} }, require: () => ({
    inputConsumer, KeyCode: { KEYCODE_VOLUME_DOWN: 1, KEYCODE_VOLUME_UP: 2 }, Action: { DOWN: 0 },
  }) })
  return { adapter: new exports.ReaderVolumeKeys({ move: intent => { moves.push(intent); return true } }),
    registrations, removed, moves }
}
test('default mapping, live reverse, and one-argument reset preserve registrations', () => {
  const f = fixture()
  assert.equal(f.adapter.setActive(true), true)
  const [down, up] = f.registrations.map(x => x.callback)
  down({ action: 0 }); up({ action: 0 })
  f.adapter.setActive(true, true)
  down({ action: 0 }); up({ action: 0 })
  f.adapter.setActive(true)
  down({ action: 0 }); up({ action: 1 })
  assert.deepEqual(f.moves, ['next', 'previous', 'previous', 'next', 'next'])
  assert.equal(f.registrations.length, 2)
})
test('close releases exact callbacks and stale callbacks cannot cross reopen', () => {
  const f = fixture()
  f.adapter.setActive(true, true)
  const old = f.registrations.map(x => x.callback)
  f.adapter.setActive(false)
  assert.deepEqual(f.removed, old)
  old.forEach(callback => callback({ action: 0 }))
  f.adapter.setActive(true)
  old.forEach(callback => callback({ action: 0 }))
  f.registrations[2].callback({ action: 0 })
  assert.deepEqual(f.moves, ['next'])
})
