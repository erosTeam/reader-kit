const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const code = ts.transpileModule(fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderKeepScreenOn.ets'), 'utf8'),
  { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText
const tick = () => new Promise(resolve => setImmediate(resolve))
function fixture(initial = false, lookup = null) {
  const exports = {}, writes = []
  let current = initial
  const win = { getWindowProperties: () => ({ isKeepScreenOn: current }),
    async setWindowKeepScreenOn(value) { writes.push(value); current = value } }
  vm.runInNewContext(code, { exports, console: { warn() {}, info() {} }, require: () => ({ window: {
    getLastWindow: lookup || (async () => win) } }) })
  return { Lease: exports.ReaderKeepScreenOn, writes, win, current: () => current }
}
test('foreground only enables and background/close restore prior policy', async () => {
  const f = fixture(), lease = new f.Lease({})
  lease.setActive(false); await tick(); assert.deepEqual(f.writes, [])
  lease.setActive(true); await tick(); assert.deepEqual(f.writes, [true])
  lease.setActive(true); await tick(); assert.deepEqual(f.writes, [true])
  lease.setActive(false); await tick(); assert.deepEqual(f.writes, [true, false])
  lease.setActive(true); await tick(); await lease.close()
  assert.deepEqual(f.writes, [true, false, true, false])
  lease.setActive(true); await tick(); assert.equal(f.current(), false)
})
test('closing during window lookup cannot enable a departed reader', async () => {
  let resolve
  const f = fixture(false, () => new Promise(done => { resolve = done })), lease = new f.Lease({})
  lease.setActive(true); await tick()
  const close = lease.close(); resolve(f.win); await close
  assert.deepEqual(f.writes, [])
})
test('pre-existing enabled window policy is not overwritten with false', async () => {
  const f = fixture(true), lease = new f.Lease({})
  lease.setActive(true); await tick(); await lease.close()
  assert.deepEqual(f.writes, [true, true]); assert.equal(f.current(), true)
})
test('new route waits for old ownership restoration before capturing its baseline', async () => {
  const f = fixture(), old = new f.Lease({}), next = new f.Lease({})
  old.setActive(true); await tick()
  const closing = old.close(); next.setActive(true); await closing; await tick()
  await next.close(); assert.deepEqual(f.writes, [true, false, true, false])
})
