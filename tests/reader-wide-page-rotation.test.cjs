const assert = require('node:assert/strict')
const test = require('node:test')
const load = require('./load-core.cjs')

const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderSnapshot } = load('ReaderSession')
const { ReaderDisplayMap, ReaderDisplayPolicy, readerPageIsWide,
  readerPolicyRotatesPage } = load('ReaderDisplayMap')
const { ReaderPagedFrame, readerPagedFrameAspectRatio } = load('ReaderPagedSession')

function page(width, height) {
  const key = new ReaderUnitKey('test', 'work', 'unit')
  const value = new ReaderPage(key, 'page-0', 0)
  value.width = width
  value.height = height
  return value
}

test('wide rotation is copied and classified only from original page metadata', () => {
  const wide = page(2400, 1200)
  wide.thumbnail.width = 100
  wide.thumbnail.height = 3000
  const policy = new ReaderDisplayPolicy()
  policy.rotateWidePages = true
  const copied = policy.copy()
  assert.equal(copied.rotateWidePages, true)
  assert.equal(readerPageIsWide(wide, copied.widePageRatio), true)
  assert.equal(readerPolicyRotatesPage(copied, wide), true)
  wide.width = 800
  wide.height = 1600
  wide.thumbnail.width = 3000
  wide.thumbnail.height = 100
  assert.equal(readerPageIsWide(wide, copied.widePageRatio), false)
  assert.equal(readerPolicyRotatesPage(copied, wide), false)
})

test('split remains mutually exclusive and rotation never changes logical topology', () => {
  const key = new ReaderUnitKey('test', 'work', 'unit')
  const wide = page(2400, 1200)
  const unit = new ReaderUnit(key, 'Unit', 1)
  const rotate = new ReaderDisplayPolicy()
  rotate.rotateWidePages = true
  const map = new ReaderDisplayMap(unit, [wide], rotate)
  assert.equal(map.count(), 1)
  assert.equal(map.item(0).parts[0].fragment, 'whole')
  rotate.splitWidePages = true
  assert.equal(readerPolicyRotatesPage(rotate, wide), false)
  const split = new ReaderDisplayMap(unit, [wide], rotate)
  assert.deepEqual([split.item(0).parts[0].fragment, split.item(1).parts[0].fragment], ['left', 'right'])
})

test('wide-page policy returns the rotated content aspect ratio', () => {
  const wide = page(2400, 1200), policy = new ReaderDisplayPolicy()
  policy.rotateWidePages = true
  const asset = new ReaderSnapshot(); asset.page = wide; asset.kind = 'original'
  const frame = new ReaderPagedFrame(1,
    new (load('ReaderDisplayMap').ReaderDisplayPart)(wide.unit, wide.key, 0), asset)
  assert.equal(readerPagedFrameAspectRatio(frame, policy), 0.5)
})

// Geometry, native rotation and progress projection require runtime tests;
// textual matches of ArkUI builders cannot establish their visual correctness.
