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

function fixture(getLastWindow, timers = { setTimeout, clearTimeout }) {
  const exports = {}, logs = [], cache = {}
  const load = name => {
    if (name === '@kit.ArkUI') return { window: { getLastWindow, AvoidAreaType: { TYPE_SYSTEM: 0 } } }
    if (name === '@kit.AbilityKit') return { ConfigurationConstant: { Direction: { DIRECTION_NOT_SET: 0, DIRECTION_HORIZONTAL: 2 } } }
    if (name === '@kit.BasicServicesKit') return { deviceInfo: { deviceType: 'phone' } }
    if (cache[name]) return cache[name]
    const result = {}; cache[name] = result
    const file = path.join(__dirname, '../reader-ui/src/main/ets', `${name.slice(2)}.ets`)
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
    }).outputText, { exports: result, require: load, ObservedV2: value => value, Trace: () => {},
      setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout,
      console: { warn: value => logs.push(value), info: value => logs.push(value) } })
    return result
  }
  vm.runInNewContext(code, {
    exports,
    ObservedV2: value => value, Trace: () => {},
    setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout,
    console: { info: value => logs.push(value), warn: value => logs.push(value) },
    require: load,
  }, { filename: 'ReaderTrialWindow.ets' })
  // Existing cases exercise ordinary no-thumbnail routes; only this test fixture
  // supplies those bindings by default. The production constructor requires them.
  class Lease extends exports.ReaderTrialWindow {
    constructor(observer = null, restore = null, entry = () => null, root = () => true) {
      super(observer, restore, entry, root)
    }
    setStatusBarVisible(visible, current = () => true) { super.setStatusBarVisible(visible, current) }
  }
  return { Lease, applyStatus: exports.applyReaderStatusBar, nativeStyle: exports.readerEntryStatusBarStyle, logs }
}

function mainWindow(write = async () => {}, visibility = async () => {}) {
  const calls = []
  let properties = { statusBarContentColor: '#FF112233', navigationBarContentColor: '#FF445566' }
  const original = { ...properties }
  return {
    original, calls,
    getWindowAvoidArea() { return { topRect: { height: 120 } } },
    getWindowSystemBarProperties() { calls.push(['read', { ...properties }]); return { ...properties } },
    async setWindowSystemBarProperties(value) {
      calls.push(['write', { ...value }])
      await write(value)
      properties = { ...properties, ...value }
    },
    async setSpecificSystemBarEnabled(name, visible, animated) {
      calls.push(['visibility', name, visible, animated])
      await visibility(visible)
    },
  }
}

// Drain promise continuations without sleeping or modelling any platform/render timing.
const drain = () => new Promise(resolve => setImmediate(resolve))

test('pending entry captures only source properties and rejects every presentation writer', async () => {
  const main = mainWindow()
  let pending = true, root = true, lookups = 0
  const entry = { pending: () => pending }
  const { Lease, applyStatus } = fixture(async () => { lookups++; return main })
  const lease = new Lease(null, true, () => entry, () => root)
  for (const state of [[true, true], [false, false]]) {
    [pending, root] = state
    lease.open({})
    lease.setStatusBarVisible(false)
    await applyStatus({}, true, { statusBarContentColor: '#FFFFFFFF' }, () => entry, () => root, () => true)
    await applyStatus({}, false, {}, () => entry, () => root, () => true)
    await drain()
    assert.equal(lookups, 1)
    assert.deepEqual(main.calls.map(call => call[0]), ['read'])
  }
  root = true
  lease.open({}); await drain()
  assert.deepEqual(main.calls.map(call => call[0]), ['read', 'visibility'])
  assert.equal(main.calls.at(-1)[2], false)
  await lease.close()
})

test('entry revocation during window lookup prevents colors and permits a later retry', async () => {
  const lookup = deferred(), main = mainWindow()
  let pending = false
  const entry = { pending: () => pending }
  const { Lease } = fixture(() => lookup.promise)
  const lease = new Lease(null, true, () => entry, () => true)
  lease.open({}); await drain()
  pending = true; lookup.resolve(main); await drain()
  assert.deepEqual(main.calls.map(call => call[0]), ['read'])
  pending = false; lease.open({}); await drain()
  assert.deepEqual(main.calls.map(call => call[0]), ['read', 'write', 'visibility'])
  await lease.close()
})

test('native navigation style follows the same content and root admission', () => {
  const { nativeStyle } = fixture(async () => mainWindow())
  let pending = true
  const entry = { pending: () => pending }
  const color = root => nativeStyle(entry, root, '#FF000000', '#FFFFFFFF', true).statusBarContentColor
  assert.equal(color(true), '#FF000000')
  pending = false
  assert.equal(color(false), '#FF000000')
  assert.equal(color(true), '#FFFFFFFF')
  assert.equal(nativeStyle(null, true, '#FF000000', '#FFFFFFFF', true).statusBarContentColor, '#FFFFFFFF')
  assert.equal(nativeStyle(entry, true, '#FF000000', '#FFFFFFFF', false).statusBarContentColor, '#FF000000')
})

test('admission replay restores the captured source colors rather than a later navigation style', async () => {
  const main = mainWindow()
  let pending = true, lookups = 0
  const { Lease } = fixture(async () => { lookups++; return main })
  const lease = new Lease(null, true, () => ({ pending: () => pending }), () => true)
  lease.open({}); await drain()
  assert.deepEqual(main.calls.map(call => call[0]), ['read'])
  await main.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
  pending = false; lease.open({}); await drain()
  assert.equal(lookups, 1)
  await lease.close()
  assert.deepEqual(main.calls.filter(call => call[0] === 'write').at(-1)[1], main.original)
})

test('queued presentation checks live root handoff and close remains a restoration path', async () => {
  const color = deferred()
  let writes = 0, root = true
  const main = mainWindow(async () => { if (++writes === 1) await color.promise })
  const { Lease } = fixture(async () => main)
  const lease = new Lease(null, true, () => null, () => root)
  lease.open({}); await drain()
  lease.setStatusBarVisible(false)
  root = false; color.resolve(); await drain()
  assert.equal(main.calls.some(call => call[0] === 'visibility'), false)
  await lease.close()
  assert.deepEqual(main.calls.at(-2), ['write', main.original])
  assert.deepEqual(main.calls.at(-1), ['visibility', 'status', true, false])
})

test('shared host writer checks root and route generation after each async boundary', async () => {
  for (const boundary of ['lookup', 'colors']) {
    const lookup = deferred(), color = deferred()
    let current = true, root = true
    const main = mainWindow(() => color.promise)
    const { applyStatus } = fixture(() => lookup.promise)
    const work = applyStatus({}, true, { statusBarContentColor: '#FFFFFFFF' }, () => null, () => root, () => current)
    if (boundary === 'lookup') {
      root = false; lookup.resolve(main)
    } else {
      lookup.resolve(main); await drain(); current = false; color.resolve()
    }
    await work
    assert.equal(main.calls.some(call => call[0] === 'visibility'), false)
    assert.equal(main.calls.filter(call => call[0] === 'write').length, boundary === 'lookup' ? 0 : 1)
  }
})

test('a retired chapter cannot dispatch queued window changes on the reused parent lease', async () => {
  const color = deferred()
  let writes = 0, oldChapterCurrent = true
  const main = mainWindow(async () => { if (++writes === 1) await color.promise })
  const { Lease } = fixture(async () => main)
  const lease = new Lease(null, true)
  lease.open({}); await drain()
  lease.setStatusBarVisible(false, () => oldChapterCurrent)
  const prepare = lease.presentation.presentChrome(true, true, true, () => oldChapterCurrent)
  oldChapterCurrent = false; color.resolve(); await drain()
  await prepare
  assert.equal(main.calls.filter(call => call[0] === 'visibility' && call[2] === false).length, 0)
  lease.setStatusBarVisible(false, () => true); await drain()
  assert.equal(main.calls.at(-1)[2], false)
  await lease.close()
  assert.deepEqual(main.calls.at(-2), ['write', main.original])
  assert.deepEqual(main.calls.at(-1), ['visibility', 'status', true, false])
})

test('opt-in close orders real area, unique host callback and colors while excluding the next lease', async () => {
  const host = deferred(), color = deferred(), main = avoidWindow(), timers = fakeTimers()
  let lookups = 0, callbacks = 0, writes = 0
  const base = main.setWindowSystemBarProperties
  main.setWindowSystemBarProperties = async value => {
    if (++writes === 2) await color.promise
    await base(value)
  }
  const { Lease } = fixture(async () => { lookups++; return main }, timers)
  const lease = new Lease(null, true), next = new Lease()
  lease.open({}); await drain()
  const closing = lease.close(async () => { callbacks++; return host.promise })
  assert.equal(lease.close(async () => { throw new Error('duplicate callback') }), closing)
  next.open({}); await drain()
  assert.equal(callbacks, 0); assert.equal(writes, 1)
  main.emit(120); await drain()
  assert.equal(callbacks, 1); assert.equal(writes, 1); assert.equal(lookups, 1)
  host.resolve(true); await drain()
  assert.equal(writes, 2); assert.equal(lookups, 1)
  color.resolve(); await closing; await drain()
  assert.equal(lookups, 2)
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'ready')
  assert.deepEqual(main.calls[4], ['write', main.original])
  await next.close()
})

test('callback false or throw remains failed after colors restore successfully', async () => {
  for (const throws of [false, true]) {
    const main = mainWindow(), events = [], { Lease } = fixture(async () => main)
    const lease = new Lease(event => events.push(event), true)
    lease.open({}); await drain()
    await lease.close(async () => { if (throws) throw new Error('host-failed'); return false })
    assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
    assert.deepEqual(main.calls.filter(call => call[0] === 'write').at(-1), ['write', main.original])
    assert.equal(events.some(event => event.includes('close_before_restore_colors_failed')), true)
    assert.equal(events.some(event => event.includes('restore_succeeded')), true)
  }
})

test('area failure skips host callback but still restores colors and reports failed', async () => {
  const main = avoidWindow(), timers = fakeTimers(), { Lease } = fixture(async () => main, timers)
  const lease = new Lease(null, true)
  lease.open({}); await drain()
  let callbacks = 0
  const closing = lease.close(async () => { callbacks++; return true })
  await drain(); timers.fire(); await closing
  assert.equal(callbacks, 0)
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
  assert.deepEqual(main.calls.at(-1), ['write', main.original])
})

test('callback and color failures are both retained in diagnostics', async () => {
  let writes = 0
  const main = mainWindow(async () => { if (++writes === 2) throw new Error('color-failed') })
  const { Lease, logs } = fixture(async () => main), lease = new Lease(null, true)
  lease.open({}); await drain()
  await lease.close(async () => { throw new Error('host-failed') })
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
  assert.equal(logs.some(log => log.includes('host-failed; restore_failed color-failed')), true)
})

test('colors-only ignores layout callbacks; explicit hidden-source restoration retains its layout boundary', async () => {
  for (const visible of [null, false]) {
    const main = mainWindow(), { Lease } = fixture(async () => main), lease = new Lease(null, visible)
    let callbacks = 0
    if (visible === false) main.getWindowAvoidArea = () => ({ topRect: { height: 0 } })
    lease.open({}); await drain()
    await lease.close(async () => { callbacks++; return true })
    assert.equal(callbacks, visible === null ? 0 : 1)
    assert.equal(lease.getCloseSystemAvoidAreaResult(), visible === null ? 'not-required' : 'ready')
    assert.deepEqual(main.calls.at(-1), ['write', main.original])
  }
})

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

function avoidWindow(visibility = async () => {}) {
  const main = mainWindow(undefined, visibility), listeners = new Set()
  main.top = 0
  main.getWindowAvoidArea = () => ({ topRect: { height: main.top } })
  main.on = (event, callback) => { assert.equal(event, 'avoidAreaChange'); listeners.add(callback) }
  main.off = (event, callback) => { assert.equal(event, 'avoidAreaChange'); listeners.delete(callback) }
  main.emit = (height, type = 0) => {
    main.top = height
    for (const callback of listeners) callback({ type, area: { topRect: { height } } })
  }
  main.listeners = listeners
  return main
}

function fakeTimers() {
  const pending = new Map()
  let next = 0
  return {
    pending,
    setTimeout(callback, ms) { assert.equal(ms, 2000); pending.set(++next, callback); return next },
    clearTimeout(id) { pending.delete(id) },
    fire() { for (const callback of [...pending.values()]) callback() },
  }
}

test('visible-area close gates on both setter and real area, then cleans up', async () => {
  const setter = deferred(), timers = fakeTimers()
  let requests = 0
  const main = avoidWindow(() => ++requests === 2 ? setter.promise : Promise.resolve())
  const { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain()
  let done = false
  const close = lease.close().then(() => { done = true })
  await drain()
  assert.equal(main.listeners.size, 1)
  main.emit(120)
  await drain(); assert.equal(done, false)
  setter.resolve(); await close
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'ready')
  assert.equal(main.listeners.size, 0); assert.equal(timers.pending.size, 0)
})

test('setter completion alone does not release close; unrelated and zero-area events do not', async () => {
  const main = avoidWindow(), timers = fakeTimers(), { Lease } = fixture(async () => main, timers)
  const lease = new Lease(null, true)
  lease.open({}); await drain()
  const close = lease.close(); await drain()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'pending')
  main.emit(0); main.emit(120, 1); await drain()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'pending')
  main.emit(120); await close
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'ready')
})

test('post-setter snapshot recovers an unreported avoid-area change', async () => {
  const main = avoidWindow(), timers = fakeTimers()
  const base = main.setSpecificSystemBarEnabled
  main.setSpecificSystemBarEnabled = async (...args) => {
    await base(...args)
    if (main.listeners.size) main.top = 120
  }
  const { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain(); await lease.close()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'ready')
  assert.equal(timers.pending.size, 0)
})

test('watchdog fails readiness and cleans up without claiming success', async () => {
  const main = avoidWindow(), timers = fakeTimers(), { Lease } = fixture(async () => main, timers)
  const lease = new Lease(null, true)
  lease.open({}); await drain()
  const close = lease.close(); await drain(); timers.fire(); await close
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
  assert.equal(main.listeners.size, 0); assert.equal(timers.pending.size, 0)
})

test('area timeout cannot release the operation queue while restoration setter is in flight', async () => {
  const setter = deferred(), timers = fakeTimers()
  let requests = 0, lookups = 0
  const main = avoidWindow(() => ++requests === 2 ? setter.promise : Promise.resolve())
  const { Lease } = fixture(async () => { lookups++; return main }, timers)
  const first = new Lease(null, true), next = new Lease()
  first.open({}); await drain()
  let closed = false
  const closing = first.close().then(() => { closed = true })
  next.open({}); await drain()
  timers.fire(); await drain()
  assert.equal(first.getCloseSystemAvoidAreaResult(), 'failed')
  assert.equal(main.listeners.size, 0); assert.equal(timers.pending.size, 0)
  assert.equal(closed, false); assert.equal(lookups, 1)
  setter.resolve(); await closing; await drain()
  assert.equal(closed, true); assert.equal(lookups, 2)
  assert.equal(first.getCloseSystemAvoidAreaResult(), 'failed')
  await next.close()
})

test('already-visible is only reported after a successful setter', async () => {
  let requests = 0
  const main = mainWindow(undefined, async () => { if (++requests === 2) throw new Error('failed') })
  const { Lease } = fixture(async () => main), lease = new Lease(null, true)
  lease.open({}); await drain(); await lease.close()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
})

test('watch registration failure still restores visibility but does not report readiness', async () => {
  const main = avoidWindow(), timers = fakeTimers()
  main.on = () => { throw new Error('watch-failed') }
  const { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain(); await lease.close()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
  assert.equal(main.calls.filter(call => call[0] === 'visibility').length, 2)
  assert.equal(timers.pending.size, 0)
})

test('setter rejection clears the registered avoid-area watcher and timer', async () => {
  let requests = 0
  const main = avoidWindow(async () => { if (++requests === 2) throw new Error('setter-failed') })
  const timers = fakeTimers(), { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain(); await lease.close()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'failed')
  assert.equal(main.listeners.size, 0); assert.equal(timers.pending.size, 0)
})

test('already-visible success requires no watcher or timer', async () => {
  const main = mainWindow(), timers = fakeTimers(), { Lease } = fixture(async () => main, timers)
  const lease = new Lease(null, true)
  lease.open({}); await drain(); await lease.close()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'already-visible')
  assert.equal(timers.pending.size, 0)
})

test('colors-only does not read avoid areas; hidden source uses its actual zero top area', async () => {
  for (const visibility of [null, false]) {
    const main = mainWindow(); let reads = 0
    main.getWindowAvoidArea = () => { reads++; return { topRect: { height: 0 } } }
    const { Lease } = fixture(async () => main), lease = new Lease(null, visibility)
    lease.open({}); await drain(); await lease.close()
    assert.equal(reads > 0, visibility === false)
    assert.equal(lease.getCloseSystemAvoidAreaResult(), visibility === null ? 'not-required' : 'ready')
  }
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
  assert.deepEqual(logs, ['[ReaderTrialWindow] status_properties_restored'])
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
  assert.equal(logs.filter(value => value.includes('open_failed=lookup-rejected') || value.includes('update_failed=open-write-rejected')).length, 2)
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
  assert.equal(main.calls.filter(value => value[0] === 'write' && value[1].statusBarContentColor === '#FFFFFFFF').length, 2)
  // Failed restoration leaves the platform white: do not invent a recovered baseline.
  assert.equal(main.calls[3][1].statusBarContentColor, '#FFFFFFFF')
  await b.close()
  assert.equal(logs.filter(value => value.includes('status_properties_restored')).length, 1)
})

test('optional observer records successful restore and readback without claiming presentation', async () => {
  const main = mainWindow(), events = [], { Lease } = fixture(async () => main)
  const lease = new Lease(event => events.push(event.replace(/^\d+ /, '')))
  lease.open({}); await drain(); await lease.close()
  assert.deepEqual(events, [
    `saved ${JSON.stringify(main.original)}`,
    `restore_called ${JSON.stringify(main.original)}`,
    'restore_succeeded',
    `restore_readback ${JSON.stringify(main.original)}`,
  ])
})

test('throwing diagnostic observer does not alter restore completion', async () => {
  const main = mainWindow(), { Lease } = fixture(async () => main)
  const lease = new Lease(() => { throw new Error('observer failure') })
  lease.open({}); await drain(); await lease.close()
  assert.deepEqual(main.getWindowSystemBarProperties(), main.original)
})

test('default lease ignores visibility requests and stays colors-only', async () => {
  const main = mainWindow(), { Lease } = fixture(async () => main)
  const lease = new Lease()
  lease.setStatusBarVisible(false)
  lease.open({}); await drain()
  lease.setStatusBarVisible(true); await drain()
  await lease.close()
  assert.equal(main.calls.some(call => call[0] === 'visibility'), false)
})

test('opt-in applies pre-open desired visibility and restores the explicit host value', async () => {
  const main = mainWindow(), events = [], { Lease } = fixture(async () => main)
  const lease = new Lease(event => events.push(event), true)
  lease.setStatusBarVisible(false)
  assert.equal(main.calls.length, 0)
  lease.open({}); await drain()
  lease.setStatusBarVisible(true); await drain()
  lease.setStatusBarVisible(false); await drain()
  await lease.close()
  lease.setStatusBarVisible(false); await drain()
  assert.deepEqual(main.calls.filter(call => call[0] === 'visibility'), [
    ['visibility', 'status', false, false], ['visibility', 'status', true, false],
    ['visibility', 'status', false, false], ['visibility', 'status', true, false],
  ])
  assert.equal(main.calls.filter(call => call[0] === 'visibility').length, 4)
})

test('opt-in defaults visible and supports restoring hidden', async () => {
  const main = mainWindow(), { Lease } = fixture(async () => main)
  const lease = new Lease(null, false)
  lease.open({}); await drain(); await lease.close()
  assert.deepEqual(main.calls.filter(call => call[0] === 'visibility'), [
    ['visibility', 'status', true, false], ['visibility', 'status', false, false],
  ])
})

test('close during color open skips desired visibility and still restores the host value', async () => {
  const writing = deferred()
  const main = mainWindow(value => value.statusBarContentColor === '#FFFFFFFF' ? writing.promise : Promise.resolve())
  const { Lease } = fixture(async () => main), lease = new Lease(null, true)
  lease.open({}); await drain()
  lease.setStatusBarVisible(false)
  const closing = lease.close()
  writing.resolve(); await closing
  assert.deepEqual(main.calls.map(call => call[0]), ['read', 'write', 'write', 'visibility'])
  assert.deepEqual(main.calls.at(-1), ['visibility', 'status', true, false])
})

test('close waits for in-flight visibility and suppresses queued updates before restoration', async () => {
  const writing = deferred()
  let requests = 0
  const main = mainWindow(undefined, () => ++requests === 1 ? writing.promise : Promise.resolve())
  const { Lease } = fixture(async () => main), lease = new Lease(null, false)
  lease.open({}); await drain()
  lease.setStatusBarVisible(true)
  let closed = false
  const closing = lease.close().then(() => { closed = true })
  await drain(); assert.equal(closed, false)
  writing.resolve(); await closing
  assert.deepEqual(main.calls.filter(call => call[0] === 'visibility'), [
    ['visibility', 'status', true, false], ['visibility', 'status', false, false],
  ])
})

test('color restoration failure still attempts visibility; both failures remain observable', async () => {
  let writes = 0, requests = 0
  const main = mainWindow(async () => { if (++writes === 2) throw new Error('color-restore-rejected') },
    async () => { if (++requests === 2) throw new Error('visibility-restore-rejected') })
  const events = [], { Lease, logs } = fixture(async () => main)
  const lease = new Lease(event => events.push(event), false)
  lease.open({}); await drain(); await lease.close()
  assert.deepEqual(main.calls.at(-1), ['visibility', 'status', false, false])
  assert.equal(events.some(event => event.includes('status_visibility_restore_failed visibility-restore-rejected')), true)
  assert.equal(logs.some(log => log.includes('color-restore-rejected; status_visibility_restore_failed visibility-restore-rejected')), true)
})

test('unchanged zero-inset source restores without waiting for a nonexistent status area', async () => {
  const main = avoidWindow(), timers = fakeTimers()
  main.getWindowProperties = () => ({ windowRect: { left: 0, top: 0, width: 980, height: 980 } })
  const { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain()
  let layoutState = null
  await lease.close(async () => { layoutState = lease.getCloseSystemAvoidAreaResult(); return true })
  assert.equal(layoutState, 'source-area-unchanged')
  assert.equal(main.listeners.size, 0)
  assert.equal(timers.pending.size, 0)
  assert.deepEqual(main.calls.at(-1), ['write', main.original])
})

test('source window resize invalidates the empty-area restoration exception', async () => {
  const main = avoidWindow(), timers = fakeTimers()
  let width = 980
  main.getWindowProperties = () => ({ windowRect: { left: 0, top: 0, width, height: 980 } })
  const { Lease } = fixture(async () => main, timers), lease = new Lease(null, true)
  lease.open({}); await drain()
  width = 1320
  const close = lease.close(); await drain()
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'pending')
  assert.equal(main.listeners.size, 1)
  main.emit(117); await close
  assert.equal(lease.getCloseSystemAvoidAreaResult(), 'ready')
  assert.equal(timers.pending.size, 0)
})
