const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderTrialWindow.ets'), 'utf8')
const code = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText

function deferred() {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}

function fixture(getLastWindow) {
  const exports = {}, logs = []
  vm.runInNewContext(code, {
    exports,
    console: { info: value => logs.push(value), warn: value => logs.push(value) },
    require: name => {
      assert.equal(name, '@kit.ArkUI')
      return { window: { getLastWindow } }
    },
  }, { filename: 'ReaderTrialWindow.ets' })
  return { Lease: exports.ReaderTrialWindow, logs }
}

function mainWindow(write = async () => {}) {
  const calls = []
  let properties = { statusBarContentColor: '#FF112233', navigationBarContentColor: '#FF445566' }
  const original = { ...properties }
  return {
    original, calls,
    getWindowSystemBarProperties() { calls.push(['read', { ...properties }]); return { ...properties } },
    async setWindowSystemBarProperties(value) {
      calls.push(['write', { ...value }])
      await write(value)
      properties = { ...properties, ...value }
    },
  }
}

// Drain promise continuations without sleeping or modelling any platform/render timing.
const drain = () => new Promise(resolve => setImmediate(resolve))

test('close before window lookup returns skips colors and preserves one-shot behavior', async () => {
  const lookup = deferred(), main = mainWindow()
  let lookups = 0
  const { Lease, logs } = fixture(() => { lookups++; return lookup.promise })
  const lease = new Lease()
  lease.open({})
  await drain()
  assert.equal(lookups, 1)
  const closing = lease.close()
  assert.equal(lease.close(), closing)
  lease.open({})
  lookup.resolve(main)
  await closing
  assert.deepEqual(main.calls, [])
  assert.deepEqual(logs, [])
  assert.equal(lookups, 1)
})

test('same-turn close before queued open never starts lookup', async () => {
  let lookups = 0
  const { Lease } = fixture(async () => { lookups++; return mainWindow() })
  const lease = new Lease()
  lease.open({})
  await lease.close()
  assert.equal(lookups, 0)
})

test('repeated open and close apply and restore once, returning the same closing promise', async () => {
  const main = mainWindow(), { Lease, logs } = fixture(async () => main)
  const lease = new Lease()
  lease.open({}); lease.open({})
  await drain()
  const closing = lease.close()
  assert.equal(lease.close(), closing)
  await closing
  assert.equal(lease.close(), closing)
  lease.open({})
  await drain()
  assert.deepEqual(main.calls.map(value => value[0]), ['read', 'write', 'write'])
  assert.deepEqual(main.calls[2][1], main.original)
  assert.deepEqual(logs, ['[ReaderTrialWindow] status_content=light', '[ReaderTrialWindow] status_properties_restored'])
})

test('close waits for an already submitted open write before restoring', async () => {
  const applied = deferred()
  const main = mainWindow(value => value.statusBarContentColor === '#FFFFFFFF' ? applied.promise : Promise.resolve())
  const { Lease } = fixture(async () => main)
  const lease = new Lease()
  lease.open({})
  await drain()
  let settled = false
  const closing = lease.close()
  closing.then(() => { settled = true })
  await drain()
  assert.equal(settled, false)
  assert.equal(main.calls.length, 2)
  applied.resolve()
  await closing
  assert.deepEqual(main.calls[2], ['write', main.original])
})

test('A restore settles before B lookup and previous-color read, then B restores that baseline', async () => {
  const restored = deferred()
  let restoreCount = 0, lookups = 0
  const main = mainWindow(value => {
    if (value.statusBarContentColor !== '#FFFFFFFF' && ++restoreCount === 1) return restored.promise
    return Promise.resolve()
  })
  const { Lease } = fixture(async () => { lookups++; return main })
  const a = new Lease(), b = new Lease()
  a.open({})
  await drain()
  const closing = a.close()
  b.open({})
  await drain()
  assert.equal(lookups, 1)
  assert.deepEqual(main.calls.map(value => value[0]), ['read', 'write', 'write'])
  restored.resolve()
  await closing
  await drain()
  assert.equal(lookups, 2)
  assert.deepEqual(main.calls[3], ['read', main.original])
  assert.equal(a.close(), closing)
  await b.close()
  assert.deepEqual(main.calls[5], ['write', main.original])
})

test('failed lookup and failed open write are observed without poisoning later operations', async () => {
  let lookups = 0, writes = 0
  const main = mainWindow(async () => { if (++writes === 1) throw new Error('open-write-rejected') })
  const { Lease, logs } = fixture(async () => {
    if (++lookups === 1) throw new Error('lookup-rejected')
    return main
  })
  const missing = new Lease()
  missing.open({}); await drain(); await missing.close()
  const failed = new Lease()
  failed.open({}); await drain(); await failed.close()
  const next = new Lease()
  next.open({}); await drain(); await next.close()
  assert.equal(logs.filter(value => value.includes('open_failed=')).length, 2)
  assert.equal(logs.filter(value => value.includes('status_content=light')).length, 1)
  assert.equal(logs.filter(value => value.includes('status_properties_restored')).length, 2)
  assert.deepEqual(main.calls.at(-1), ['write', main.original])
})

test('failed restore is logged, not reported restored, and later lease operations still execute', async () => {
  let writes = 0
  const main = mainWindow(async () => { if (++writes === 2) throw new Error('restore-rejected') })
  const { Lease, logs } = fixture(async () => main)
  const a = new Lease(), b = new Lease()
  a.open({}); await drain()
  const closing = a.close()
  b.open({})
  await closing; await drain()
  assert.equal(logs.filter(value => value.includes('restore_failed=restore-rejected')).length, 1)
  assert.equal(logs.filter(value => value.includes('status_properties_restored')).length, 0)
  assert.equal(logs.filter(value => value.includes('status_content=light')).length, 2)
  // Failed restoration leaves the platform white: do not invent a recovered baseline.
  assert.equal(main.calls[3][1].statusBarContentColor, '#FFFFFFFF')
  await b.close()
  assert.equal(logs.filter(value => value.includes('status_properties_restored')).length, 1)
})
