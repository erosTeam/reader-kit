const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const code = ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderTrialLayoutCommit.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText

function fixture() {
  const exports = {}, frames = [], timers = new Map()
  let timerId = 0
  vm.runInNewContext(code, {
    exports,
    require: name => {
      assert.equal(name, '@kit.ArkUI')
      return { FrameCallback: class {} }
    },
    setTimeout: (callback, ms) => { assert.equal(ms, 2000); timers.set(++timerId, callback); return timerId },
    clearTimeout: id => timers.delete(id),
  })
  return { helper: exports.ReaderTrialLayoutCommit, frames, timers,
    context: { postFrameCallback: callback => frames.push(callback) },
    frame: () => { const callback = frames.shift(); assert.ok(callback); callback.onIdle(0); return callback },
  }
}

test('two same nonempty frame samples resolve true without requiring movement', async () => {
  const f = fixture(); let samples = 0
  const result = f.helper.wait(f.context, () => { samples++; return 'existing-layout' }, () => true)
  f.frame(); assert.equal(f.timers.size, 1)
  const last = f.frame()
  assert.equal(await result, true); assert.equal(f.timers.size, 0)
  last.onIdle(0); assert.equal(samples, 2); assert.equal(f.frames.length, 0)
})

test('empty or changed keys interrupt consecutive stability', async () => {
  const f = fixture(), keys = ['a', '', 'a', 'b', 'b']
  const result = f.helper.wait(f.context, () => keys.shift(), () => true)
  for (let i = 0; i < 4; i++) { f.frame(); assert.equal(f.timers.size, 1) }
  f.frame(); assert.equal(await result, true); assert.equal(f.timers.size, 0)
})

test('sixty unready frames fail and clear watchdog', async () => {
  const f = fixture(); let samples = 0
  const result = f.helper.wait(f.context, () => String(++samples), () => true)
  for (let i = 0; i < 60; i++) f.frame()
  assert.equal(await result, false); assert.equal(samples, 60)
  assert.equal(f.frames.length, 0); assert.equal(f.timers.size, 0)
})

test('watchdog fails when no frame arrives; late callback never samples', async () => {
  const f = fixture(); let samples = 0
  const result = f.helper.wait(f.context, () => { samples++; return 'x' }, () => true)
  const timeout = [...f.timers.values()][0]
  timeout(); assert.equal(await result, false)
  f.frame(); timeout(); assert.equal(samples, 0); assert.equal(f.timers.size, 0)
})

test('cancelled before scheduling or while waiting never samples retired state', async () => {
  const f = fixture(); let current = false, samples = 0
  assert.equal(await f.helper.wait(f.context, () => { samples++; return 'x' }, () => current), false)
  assert.equal(f.frames.length, 0)
  current = true
  const result = f.helper.wait(f.context, () => { samples++; return 'x' }, () => current)
  current = false; f.frame()
  assert.equal(await result, false); assert.equal(samples, 0); assert.equal(f.timers.size, 0)
})

test('sample invalidation cannot produce a successful second frame', async () => {
  const f = fixture(); let current = true, samples = 0
  const result = f.helper.wait(f.context, () => { if (++samples === 2) current = false; return 'x' }, () => current)
  f.frame(); f.frame(); assert.equal(await result, false); assert.equal(f.timers.size, 0)
})

test('sampling, current checks and scheduling exceptions resolve false and clear watchdog', async () => {
  for (const failure of ['sample', 'current', 'schedule']) {
    const f = fixture(), fail = () => { throw new Error(failure) }
    if (failure === 'schedule') f.context.postFrameCallback = fail
    const result = f.helper.wait(f.context, failure === 'sample' ? fail : () => 'x',
      failure === 'current' ? fail : () => true)
    if (failure === 'sample') f.frame()
    assert.equal(await result, false); assert.equal(f.timers.size, 0)
  }
})
