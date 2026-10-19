const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSystemBarController.ets'), 'utf8')
function fixture() {
  const exports = {}, calls = [], logs = []
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true,
  } }).outputText, { exports, ObservedV2: value => value, Trace: () => {},
    require: name => {
      assert.equal(name, '@kit.ArkUI')
      return { window: { AvoidAreaType: { TYPE_SYSTEM: 0 } } }
    },
    console: { warn: value => logs.push(value) } })
  const win = {
    async setWindowSystemBarProperties(value) { calls.push(['color', value.statusBarContentColor]) },
    async setSpecificSystemBarEnabled(_name, visible) { calls.push(['visible', visible]) },
    getWindowAvoidArea() { throw new Error('chrome must never wait for a system inset') },
  }
  const controller = new exports.ReaderSystemBarController(async () => win, () => true)
  return { controller, Controller: exports.ReaderSystemBarController, calls, win, logs }
}
const drain = () => new Promise(resolve => setImmediate(resolve))
function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes }); return { resolve, promise } }

test('reveal applies light color then visibility without consulting a system inset', async () => {
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
