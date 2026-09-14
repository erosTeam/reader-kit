const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const load = require('./load-core.cjs')

const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderSnapshot } = load('ReaderSession')
const { ReaderDisplayMap, ReaderDisplayPolicy, readerPageIsWide,
  readerPolicyRotatesPage } = load('ReaderDisplayMap')
const { ReaderPagedFrame, readerPagedFrameAspectRatio } = load('ReaderPagedSession')
const root = path.resolve(__dirname, '..')
const paged = fs.readFileSync(path.join(root, 'reader-ui/src/main/ets/ReaderPagedViewport.ets'), 'utf8')
const continuous = fs.readFileSync(path.join(root, 'reader-ui/src/main/ets/ReaderContinuousSurface.ets'), 'utf8')
const zoom = fs.readFileSync(path.join(root, 'reader-ui/src/main/ets/ReaderContinuousZoomImage.ets'), 'utf8')

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

test('paged rendering swaps fitted geometry, rotates clockwise, resets zoom and cancels entry morph', () => {
  assert.match(paged, /function rotatedFrame\([\s\S]*?readerPolicyRotatesPage/)
  assert.match(paged, /readerPagedFrameAspectRatio\(frame, this\.snapshot\.policy\)/)
  const wide = page(2400, 1200), policy = new ReaderDisplayPolicy()
  policy.rotateWidePages = true
  const asset = new ReaderSnapshot(); asset.page = wide; asset.kind = 'original'
  const frame = new ReaderPagedFrame(1,
    new (load('ReaderDisplayMap').ReaderDisplayPart)(wide.unit, wide.key, 0), asset)
  assert.equal(readerPagedFrameAspectRatio(frame, policy), 0.5)
  assert.match(paged, /snapshot\.policy\.rotateWidePages/)
  assert.match(paged, /private renderWidth\(\): number \{ return this\.rotateClockwise \? this\.viewportHeight : this\.viewportWidth \}/)
  assert.match(paged, /private renderHeight\(\): number \{ return this\.rotateClockwise \? this\.viewportWidth : this\.viewportHeight \}/)
  assert.match(paged, /\.rotate\(\{ angle: this\.rotateClockwise \? 90 : 0 \}\)/)
  assert.match(paged, /if \(this\.rotateClockwise\) \{ transition\.cancel\(\); return \}/)
})

test('continuous rotation swaps row ratio, zoom pixels and original-coordinate progress axes', () => {
  assert.match(continuous, /readerPolicyRotatesPage\(this\.snapshot\.policy, page \?\? null\)/)
  assert.match(continuous, /return originalRatio > 0 \? 1 \/ originalRatio : 0\.75/)
  assert.match(continuous, /const sourcePosition = rotated \? \(defaultStart \? crop\.left : sourceX\) : sourceY/)
  assert.match(continuous, /rotated \? region\.sourceX\(y\) : region\.sourceX\(0\.5\)/)
  assert.match(continuous, /rotated \? region\.sourceY\(0\.5\) : region\.sourceY\(y\)/)
  assert.match(zoom, /this\.rotateClockwise \? \(page\?\.height \?\? 0\)[\s\S]*?rotateClockwise: this\.rotateClockwise/)
})
