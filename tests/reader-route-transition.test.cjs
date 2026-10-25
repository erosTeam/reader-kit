const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
function load(name, imports = {}) {
  const exports = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets', name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, { exports, require: key => imports[key] ?? {}, ObservedV2: x => x, Trace() {},
    Curve: { FastOutSlowIn: 'curve' }, console: { info() {}, warn() {} } })
  return exports
}
const { ReaderRouteTransition } = load('ReaderRouteTransition')
const { ReaderSystemBarController } = load('ReaderSystemBarController')
function fixture() {
  const state = new ReaderRouteTransition(), animations = [], ends = []
  let finishes = 0
  state.begin()
  const delegate = state.transition({ animateTo(options, update) { animations.push(options); update() } }, success => ends.push(success))
  delegate.transition({ finishTransition() { finishes++ } })
  return { state, animations, ends, delegate, finishes: () => finishes }
}
test('native shown or animation target alone cannot admit a Window write; both actual completions are required', async () => {
  const f = fixture(), writes = []
  const win = { async setWindowSystemBarProperties() {}, async setSpecificSystemBarEnabled(...a) { writes.push(a) } }
  const controller = new ReaderSystemBarController(async () => win, () => f.state.ready())
  await controller.presentChrome(false, true, true, () => true)
  assert.equal(f.state.progress, 1); assert.equal(f.state.ready(), false); assert.equal(writes.length, 0)
  f.animations[0].onFinish(); assert.equal(f.finishes(), 1)
  await controller.replay(); assert.equal(writes.length, 0)
  f.delegate.onTransitionEnd(true); await controller.replay()
  assert.equal(f.state.ready(), true); assert.equal(writes.length, 1); assert.equal(writes[0][1], false)
})
test('a native timeout marked successful cannot impersonate the animation finish callback', () => {
  const f = fixture(); f.delegate.onTransitionEnd(true)
  assert.equal(f.state.ready(), false); assert.deepEqual(f.ends, [false])
  f.animations[0].onFinish(); assert.equal(f.finishes(), 0); assert.equal(f.state.ready(), false)
})
test('native failure remains unadmitted even if the animation callback already completed', () => {
  const f = fixture(); f.animations[0].onFinish(); f.delegate.onTransitionEnd(false)
  assert.equal(f.state.ready(), false); assert.deepEqual(f.ends, [false])
})
test('close then immediate reopen rejects both old completion callbacks', () => {
  const f = fixture(); f.state.cancel(); f.state.begin()
  f.animations[0].onFinish(); f.delegate.onTransitionEnd(true)
  assert.equal(f.finishes(), 0); assert.equal(f.state.phase, 'armed'); assert.equal(f.state.ready(), false)
})
test('a finished route remains ready across a host sheet or retained-detail roundtrip', () => {
  const f = fixture(); f.animations[0].onFinish(); f.delegate.onTransitionEnd(true); f.state.cancel()
  assert.equal(f.state.ready(), true); assert.equal(f.state.offset(), '0%')
  f.state.begin(); assert.equal(f.state.ready(), false); f.state.skip(); assert.equal(f.state.ready(), true)
})
