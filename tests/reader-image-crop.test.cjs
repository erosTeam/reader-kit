const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderImageCropBounds } = load('ReaderImageCrop')
const { ReaderDisplayPart } = load('ReaderDisplayMap')
const { ReaderDisplayPolicy } = load('ReaderDisplayMap')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const key = new ReaderUnitKey('source', 'work', 'unit')
const part = fragment => new ReaderDisplayPart(key, 'page', 0, fragment)
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-10, `${a} != ${b}`)
test('crop intersects original half-page boundary without re-splitting cropped content', () => {
  const crop = new ReaderImageCropBounds(.1, .2, .3, .1)
  const left = crop.region(part('left')), right = crop.region(part('right'))
  close(left.x, .1); close(left.width, .4)
  close(right.x, .5); close(right.width, .2)
  close(left.sourceX(1), right.sourceX(0)); close(right.sourceX(1), .7)
  close(right.sourceY(.4), .48); close(right.localY(.48), .4)
  close(right.localX(right.sourceX(.75)), .75)
  assert.equal(right.localX(0), 0); assert.equal(right.localX(1), 1)
})
test('continuous crop preserves internal seams and handles a one-page unit', () => {
  const crop = new ReaderImageCropBounds(.1, .2, .1, .3)
  for (const [index, top, bottom] of [[0, .2, 0], [1, 0, 0], [2, 0, .3]]) {
    const result = crop.forContinuousPage(index, 3)
    assert.equal(result.top, top); assert.equal(result.bottom, bottom)
    assert.equal(result.left, .1); assert.equal(result.right, .1)
  }
  assert.equal(crop.forContinuousPage(0, 1).bottom, .3)
  assert.equal(crop.forContinuousPage(0, 0).bottom, 0)
})
test('invalid insets cannot make either original half empty', () => {
  const crop = new ReaderImageCropBounds(Infinity, -.2, 9, NaN)
  assert.equal(crop.left, 0); assert.equal(crop.top, 0); assert.equal(crop.bottom, 0)
  assert.ok(crop.region(part('right')).width > 0)
})
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r }); return { promise, resolve } }
async function fixture(read) {
  const assets = { cancellationMode: 'consumer-only', async load(page) {
    const asset = new ReaderAsset('same-file'); asset.crop = { read }; return asset
  } }
  const catalog = { async open() { return new ReaderUnit(key, 'unit', 2) },
    async page(unit, index) { return new ReaderPage(unit.key, `page-${index}`, index) }, adjacent() { return null } }
  const session = new ReaderSession(catalog, assets)
  await session.open(key)
  return session
}
test('default body can read crop without changing decode state or original metadata', async () => {
  const bounds = new ReaderImageCropBounds(.1, .2)
  const session = await fixture(async () => bounds), before = session.snapshot()
  const result = await session.imageCrop(before.assetRequestId)
  assert.equal(result.top, .2); assert.notEqual(result, bounds)
  result.top = 0; assert.equal(bounds.top, .2)
  assert.equal(session.snapshot().phase, 'decoding')
  assert.equal(session.snapshot().page.width, before.page.width)
  session.close()
})
test('same-file reload invalidates old detection and accepts the new asset only', async () => {
  const old = deferred(), session = await fixture(() => old.promise)
  const pending = session.imageCrop(session.snapshot().assetRequestId)
  await session.retry()
  old.resolve(new ReaderImageCropBounds(.1))
  assert.equal(await pending, null)
  assert.equal((await session.imageCrop(session.snapshot().assetRequestId)).left, .1)
  session.close()
})
test('navigation and close reject late crop completion', async () => {
  for (const action of ['navigate', 'close']) {
    const old = deferred(), session = await fixture(() => old.promise)
    const pending = session.imageCrop(session.snapshot().assetRequestId)
    if (action === 'navigate') await session.show(1); else session.close()
    old.resolve(new ReaderImageCropBounds(.2))
    assert.equal(await pending, null); session.close()
  }
})
test('detection failure leaves the displayed body readable', async () => {
  const session = await fixture(async () => { throw Error('detection failed') })
  const id = session.snapshot().assetRequestId
  session.reportPresentation(id, true)
  assert.equal(await session.imageCrop(id), null)
  assert.equal(session.snapshot().phase, 'displayed')
  session.close()
})

test('paged crop is opt-in, reversible, asset-scoped and never changes topology', async () => {
  let reads = 0
  const catalog = { async open() { return new ReaderUnit(key, 'unit', 3) },
    async page(unit, index) { const p = new ReaderPage(unit.key, `p${index}`, index); p.width = 800; p.height = 1200; return p },
    adjacent() { return null } }
  const assets = { cancellationMode: 'consumer-only', async load() {
    const asset = new ReaderAsset('same-file')
    asset.crop = { async read() { reads++; return new ReaderImageCropBounds(.1, .2, .1, .3) } }
    return asset
  } }
  const session = new ReaderPagedSession(catalog, assets), tick = () => new Promise(setImmediate)
  await session.open(key); await tick()
  const before = session.snapshot()
  assert.equal(reads, 0)
  session.setCropEnabled(true); await tick()
  let after = session.snapshot()
  assert.equal(reads, 1); assert.equal(after.frames[0].crop.top, .2)
  assert.equal(after.topologyRevision, before.topologyRevision)
  assert.equal(after.frames[0].asset.page.width, 800)
  session.setCropEnabled(false); assert.equal(session.snapshot().frames[0].crop.top, 0)
  session.setCropEnabled(true); await tick(); assert.equal(reads, 1)
  session.setPolicy(Object.assign(new ReaderDisplayPolicy(), { layout: 'continuous' })); await tick()
  assert.equal(session.snapshot().frames[0].crop.top, .2)
  assert.equal(session.snapshot().frames[0].crop.bottom, 0)
  session.move('next'); await tick()
  after = session.snapshot()
  assert.equal(after.frames[0].part.sourceIndex, 1)
  assert.equal(after.frames[0].crop.top, 0); assert.equal(after.frames[0].crop.bottom, 0)
  session.move('next'); await tick()
  assert.equal(session.snapshot().frames[0].crop.bottom, .3)
  assert.equal(session.snapshot().window.some(item => item.frames.some(frame => frame.part.sourceIndex === 0)), false)
  assert.equal(session.snapshot().cropForPage(0).top, .2)
  assert.equal(session.snapshot().cropForPage(0).left, .1)
  session.setCropEnabled(false)
  assert.equal(session.snapshot().cropForPage(0).top, 0)
  session.setCropEnabled(true)
  assert.equal(session.snapshot().cropForPage(0).top, .2)
  session.close()
})
