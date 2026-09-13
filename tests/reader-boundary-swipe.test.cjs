const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderBoundarySwipe.ets'), 'utf8')
const evaluated = {}
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: evaluated })
const { ReaderBoundarySwipe } = evaluated

function swipe(options) {
  const value = new ReaderBoundarySwipe()
  value.begin(100, 100, options.previous ?? false, options.next ?? false)
  return value.finish(options.x ?? 100, options.y ?? 100,
    options.axis ?? 'horizontal', options.direction ?? 'ltr')
}

test('paged boundary maps physical direction through LTR, RTL and vertical axes', () => {
  assert.equal(swipe({ next: true, x: 20 }), 'next')
  assert.equal(swipe({ previous: true, x: 180 }), 'previous')
  assert.equal(swipe({ next: true, x: 180, direction: 'rtl' }), 'next')
  assert.equal(swipe({ previous: true, x: 20, direction: 'rtl' }), 'previous')
  assert.equal(swipe({ next: true, y: 20, axis: 'vertical' }), 'next')
  assert.equal(swipe({ previous: true, y: 180, axis: 'vertical' }), 'previous')
})

test('continuous one-page boundary selects intent from the completed drag direction', () => {
  assert.equal(swipe({ previous: true, next: true, y: 20, axis: 'vertical' }), 'next')
  assert.equal(swipe({ previous: true, next: true, y: 180, axis: 'vertical' }), 'previous')
})

test('wrong edge, short, cross-axis and cancelled sequences are rejected', () => {
  assert.equal(swipe({ previous: true, x: 20 }), null)
  assert.equal(swipe({ next: true, x: 70 }), null)
  assert.equal(swipe({ next: true, x: 20, y: 190 }), null)
  const cancelled = new ReaderBoundarySwipe()
  cancelled.begin(100, 100, false, true)
  cancelled.cancel()
  assert.equal(cancelled.finish(0, 100, 'horizontal'), null)
})
