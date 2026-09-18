const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderTapSequence.ets'), 'utf8')
const exportsValue = {}
const TouchType = { Down: 'Down', Move: 'Move', Up: 'Up', Cancel: 'Cancel' }
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: exportsValue, TouchType })
const { ReaderTapSequence, READER_TAP_MOVE_TOLERANCE } = exportsValue

function walkTap(sequence, x, y, touchType) {
  sequence.touch({ type: touchType, touches: [{ x, y }], changedTouches: [{ x, y }] })
}

test('a still finger is an allowed tap', () => {
  const sequence = new ReaderTapSequence()
  walkTap(sequence, 300, 800, TouchType.Down)
  assert.equal(sequence.allowed(), true)
})

test('a small finger travel within tolerance is still a tap', () => {
  const sequence = new ReaderTapSequence()
  walkTap(sequence, 300, 800, TouchType.Down)
  walkTap(sequence, 300 + READER_TAP_MOVE_TOLERANCE - 1, 800, TouchType.Move)
  assert.equal(sequence.allowed(), true)
})

test('a cross-axis drag past tolerance is not a tap', () => {
  for (const direction of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const sequence = new ReaderTapSequence()
    walkTap(sequence, 630, 1360, TouchType.Down)
    for (const step of [40, 120, 320, 700]) {
      walkTap(sequence, 630 + direction[0] * step, 1360 + direction[1] * step, TouchType.Move)
    }
    assert.equal(sequence.allowed(), false)
  }
})

test('a new down on a single finger resets the previous drag suppression', () => {
  const sequence = new ReaderTapSequence()
  walkTap(sequence, 630, 1360, TouchType.Down)
  walkTap(sequence, 630, 2200, TouchType.Move)
  assert.equal(sequence.allowed(), false)
  walkTap(sequence, 630, 1360, TouchType.Down)
  assert.equal(sequence.allowed(), true)
})

test('a multi-touch down or a cancelled gesture is not a tap', () => {
  const fromMulti = new ReaderTapSequence()
  fromMulti.touch({ type: TouchType.Down, touches: [{ x: 100, y: 100 }, { x: 200, y: 200 }], changedTouches: [{ x: 100, y: 100 }] })
  assert.equal(fromMulti.allowed(), false)

  const cancelled = new ReaderTapSequence()
  walkTap(cancelled, 300, 800, TouchType.Down)
  walkTap(cancelled, 300, 800, TouchType.Cancel)
  assert.equal(cancelled.allowed(), false)
})
