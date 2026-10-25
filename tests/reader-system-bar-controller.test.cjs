const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSystemBarController.ets'), 'utf8')
function fixture(timers = { setTimeout, clearTimeout }) {
  const exports = {}, calls = [], logs = []
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true,
  } }).outputText, { exports, ObservedV2: value => value, Trace: () => {},
    require: name => {
      assert.equal(name, '@kit.ArkUI')
      return { window: { AvoidAreaType: { TYPE_SYSTEM: 0 }, WindowStatusType: { FULL_SCREEN: 1, MAXIMIZE: 2 } } }
    },
    setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout,
    console: { warn: value => logs.push(value) } })
  const win = {
    async setWindowSystemBarProperties(value) { calls.push(['color', value.statusBarContentColor]) },
    async setSpecificSystemBarEnabled(_name, visible) { calls.push(['visible', visible]) },
    getWindowAvoidArea() { throw new Error('geometry unavailable') },
  }
  const controller = new exports.ReaderSystemBarController(async () => win, () => true)
  return { controller, Controller: exports.ReaderSystemBarController, calls, win, logs }
}
const drain = () => new Promise(resolve => setImmediate(resolve))
function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes }); return { resolve, promise } }

test('unavailable geometry does not block light color and visibility', async () => {
  const { controller, calls } = fixture()
  await controller.presentChrome(true, true, false, () => true)
  assert.deepEqual(calls, [['color', '#FFFFFFFF'], ['visible', true]])
})

test('fullscreen, chrome and canvas project one visibility and color intent', async () => {
  const { controller, calls } = fixture()
  for (const row of [[false,true,false], [false,false,false], [false,false,true], [true,true,false]]) {
    calls.length = 0
    await controller.presentChrome(...row, () => true)
    assert.deepEqual(calls, row[0] || !row[1]
      ? [['color', row[0] || row[2] ? '#FFFFFFFF' : '#FF000000'], ['visible', true]]
      : [['visible', false]])
  }
})

test('a later hide retires a show waiting for window lookup', async () => {
  const { Controller, win, calls } = fixture(), lookup = deferred()
  let first = true
  const controller = new Controller(() => { if (first) { first = false; return lookup.promise }; return Promise.resolve(win) }, () => true)
  const showing = controller.presentChrome(true, true, true, () => true)
  await drain()
  const hiding = controller.presentChrome(false, true, true, () => true)
  lookup.resolve(win)
  await Promise.all([showing, hiding])
  assert.deepEqual(calls, [['visible', false]])
})

test('a newer hide prevents an in-flight color setter from revealing the bar', async () => {
  const { controller, win, calls } = fixture(), color = deferred()
  win.setWindowSystemBarProperties = async () => { calls.push(['color-start']); await color.promise; calls.push(['color-end']) }
  const showing = controller.presentChrome(true, true, true, () => true)
  await drain()
  const hiding = controller.presentChrome(false, true, true, () => true)
  color.resolve()
  await Promise.all([showing, hiding])
  assert.deepEqual(calls, [['color-start'], ['color-end'], ['visible', false]])
})

test('source restoration follows in-flight work and keeps its exact properties', async () => {
  const { controller, win, calls } = fixture(), visibility = deferred()
  win.setSpecificSystemBarEnabled = async (_name, visible) => { calls.push(['visible', visible]); if (visible) await visibility.promise }
  const showing = controller.presentChrome(true, true, true, () => true)
  await drain()
  const restoring = controller.request(false, { statusBarContentColor: '#FF112233' }, () => true, true)
  visibility.resolve()
  await Promise.all([showing, restoring])
  assert.deepEqual(calls, [['color', '#FFFFFFFF'], ['visible', true], ['color', '#FF112233'], ['visible', false]])
})

test('closing and caller retirement suppress queued presentation', async () => {
  for (const close of [false, true]) {
    const { controller, win, calls } = fixture(), color = deferred()
    let current = true
    win.setWindowSystemBarProperties = async () => { calls.push(['color']); await color.promise }
    const showing = controller.presentChrome(true, true, true, () => current)
    await drain()
    current = false
    const closed = close ? controller.cancel() : Promise.resolve()
    color.resolve(); await Promise.all([showing, closed])
    assert.deepEqual(calls, [['color']])
  }
})

test('entry admission defers native writes and replays the retained intent', async () => {
  const { Controller, calls, win } = fixture()
  let admitted = false
  const controller = new Controller(async () => win, () => admitted)
  await controller.presentChrome(true, true, true, () => true)
  assert.deepEqual(calls, [])
  admitted = true; await controller.replay()
  assert.deepEqual(calls, [['color', '#FFFFFFFF'], ['visible', true]])
})

test('platform failure is contained and a later chrome request can still apply', async () => {
  const { controller, calls, win, logs } = fixture()
  const color = win.setWindowSystemBarProperties
  win.setWindowSystemBarProperties = async () => { throw new Error('rejected') }
  await controller.presentChrome(true, true, true, () => true)
  assert.deepEqual(calls, []); assert.equal(logs.length, 1)
  win.setWindowSystemBarProperties = color
  await controller.presentChrome(true, true, true, () => true)
  assert.deepEqual(calls, [['color', '#FFFFFFFF'], ['visible', true]])
})

// Real197/117: setter returned with systemPx=0; the area arrived after reveal.
// This replaces the former blanket 'never consult an inset' premise, not a UI assertion.
function statusWindow(win, initialHeight = 123, status = 1) {
  let height = initialHeight
  const listeners = new Set()
  win.getWindowProperties = () => ({ windowRect: { left: 0, top: 0, width: 1260, height: 2720 } })
  win.getWindowStatus = () => status
  win.getWindowAvoidArea = () => ({ topRect: { height } })
  win.on = (_event, listener) => listeners.add(listener)
  win.off = (_event, listener) => listeners.delete(listener)
  return {
    listeners,
    set(value) { height = value },
    emit(value) { height = value; for (const listener of [...listeners]) listener({ type: 0 }) },
  }
}

test('a real status-area window waits beyond the setter until the show area arrives', async () => {
  const { controller, win, calls } = fixture(), area = statusWindow(win)
  await controller.presentChrome(false, true, true, () => true)
  area.set(0)
  let completed = false
  const showing = controller.presentChrome(true, true, true, () => true).then(() => { completed = true })
  await drain()
  assert.equal(calls.at(-1)[0], 'visible'); assert.equal(completed, false)
  area.emit(0); await drain(); assert.equal(completed, false)
  const count = calls.length, replay = controller.replay()
  await drain(); assert.equal(completed, false); assert.equal(calls.length, count)
  area.emit(123); await Promise.all([showing, replay])
  assert.equal(completed, true); assert.equal(area.listeners.size, 0)
})

test('hide or close retires an area waiter without holding the native queue', async () => {
  for (const closing of [false, true]) {
    const { controller, win, calls } = fixture(), area = statusWindow(win)
    await controller.presentChrome(false, true, true, () => true); area.set(0)
    const showing = controller.presentChrome(true, true, true, () => true)
    await drain(); assert.equal(area.listeners.size, 1)
    if (closing) await controller.cancel()
    else await controller.presentChrome(false, true, true, () => true)
    await showing; assert.equal(area.listeners.size, 0)
    const count = calls.length; area.emit(123); await drain(); assert.equal(calls.length, count)
    if (!closing) assert.deepEqual(calls.at(-1), ['visible', false])
  }
})

test('zero-area and floating windows settle immediately; a missing signal has finite failure recovery', async () => {
  for (const [height, status] of [[0, 1], [123, 3]]) {
    const { controller, win } = fixture(), area = statusWindow(win, height, status)
    await controller.presentChrome(true, true, true, () => true)
    assert.equal(area.listeners.size, 0)
  }
  let watchdog
  const timers = { setTimeout(callback) { watchdog = callback; return 1 }, clearTimeout() {} }
  const { controller, win, logs } = fixture(timers), area = statusWindow(win)
  await controller.presentChrome(false, true, true, () => true); area.set(0)
  const showing = controller.presentChrome(true, true, true, () => true)
  await drain(); watchdog(); await showing
  assert.equal(area.listeners.size, 0)
  assert.equal(logs.filter(value => value.includes('chrome_status_area_unavailable')).length, 1)
})
