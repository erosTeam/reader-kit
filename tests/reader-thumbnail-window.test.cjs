const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderThumbnailWindow } = load('ReaderThumbnailWindow')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const { ReaderPagedSession } = load('ReaderPagedSession')
const tick = () => new Promise(resolve => setImmediate(resolve))

function setup({ deferred = false, unavailable = false, sprite = false } = {}) {
  const unit = new ReaderUnit(new ReaderUnitKey('source', 'work', 'A'), 'A', 40)
  const calls = { open: 0, page: [], load: [], release: [], pending: [] }
  const catalog = {
    async open(key) { calls.open++; return new ReaderUnit(key, key.unit, 40) },
    async page(unit, index) {
      calls.page.push([unit.key.unit, index])
      const p = new ReaderPage(unit.key, `${unit.key.unit}-${index}`, index)
      p.width = 720; p.height = 9200
      p.thumbnail.available = !unavailable
      p.thumbnail.kind = sprite ? 'sprite' : 'image'
      p.thumbnail.width = 200; p.thumbnail.height = 300
      p.thumbnail.offsetX = sprite ? 400 : 0
      return p
    },
    adjacent() { return null },
  }
  const assets = {
    cancellationMode: 'consumer-only',
    async load(page, kind, cancellation, force) {
      calls.load.push([page.key, kind, force])
      const result = new ReaderAsset(`${kind}:${page.key}`, () => calls.release.push(`${kind}:${page.key}`))
      if (deferred) return new Promise(resolve => calls.pending.push(() => resolve(result)))
      return result
    },
  }
  return { unit, catalog, assets, calls, window: new ReaderThumbnailWindow(catalog, assets) }
}

test('rail requests only visible plus neighboring thumbnails without reopening catalog', async () => {
  const { window, unit, calls } = setup()
  window.setRange(unit, 10, 13); await tick()
  assert.deepEqual(calls.page.map(p => p[1]), [9, 10, 11, 12, 13, 14])
  assert.equal(calls.open, 0)
  assert.ok(calls.load.every(c => c[1] === 'thumbnail'))
  const retained = window.snapshot().find(f => f.index === 12)
  window.setRange(unit, 12, 15); await tick()
  assert.equal(window.snapshot().find(f => f.index === 12).slotId, retained.slotId)
  assert.deepEqual(calls.release, ['thumbnail:A-9', 'thumbnail:A-10'])
  assert.equal(calls.load.length, 8)
  window.close()
  assert.equal(calls.release.length, 8)
})

test('retired asynchronous thumbnails release late leases and reject old native callbacks', async () => {
  const { window, unit, calls } = setup({ deferred: true })
  window.setRange(unit, 0, 0); await tick()
  const old = window.snapshot()[0]
  window.setRange(unit, 20, 20); await tick()
  calls.pending.splice(0, 2).forEach(resolve => resolve()); await tick()
  assert.equal(calls.release.length, 2)
  window.reportPresentation(old.slotId, 1, true, 100, 100)
  assert.deepEqual(window.snapshot().map(f => f.index), [19, 20, 21])
  window.close(); calls.pending.forEach(resolve => resolve()); await tick()
  assert.equal(calls.release.length, 5)
  assert.deepEqual(window.snapshot(), [])
})

test('independent preview decode dimensions never overwrite original or sprite crop geometry', async () => {
  for (const sprite of [false, true]) {
    const { window, unit } = setup({ sprite })
    window.setRange(unit, 0, 0); await tick()
    const f = window.snapshot()[0]
    window.reportPresentation(f.slotId, f.asset.assetRequestId, true, 4000, 350)
    const page = window.snapshot()[0].asset.page
    assert.equal(page.width, 720); assert.equal(page.height, 9200)
    assert.equal(page.thumbnail.width, sprite ? 200 : 4000)
    assert.equal(page.thumbnail.height, sprite ? 300 : 350)
    assert.equal(page.thumbnail.offsetX, sprite ? 400 : 0)
    assert.equal(window.snapshot()[0].asset.presentedAnchor, null)
    window.close()
  }
})

test('unavailable thumbnail is explicit and never requests original or fake retry', async () => {
  const { window, unit, calls } = setup({ unavailable: true })
  window.setRange(unit, 0, 0); await tick()
  assert.equal(calls.load.length, 0)
  const f = window.snapshot()[0]
  assert.equal(f.asset.phase, 'failed')
  assert.equal(f.asset.page.thumbnail.available, false)
  assert.equal(await window.retry(f.slotId, f.asset.requestId), false)
  window.close()
})

test('thumbnail retry is exact and leaves healthy sibling lease unchanged', async () => {
  const { window, unit, calls } = setup()
  window.setRange(unit, 0, 1); await tick()
  const [failed, healthy] = window.snapshot()
  window.reportPresentation(failed.slotId, failed.asset.assetRequestId, false)
  assert.equal(await window.retry(failed.slotId, failed.asset.requestId + 1), false)
  assert.equal(await window.retry(failed.slotId, failed.asset.requestId), true)
  await tick()
  assert.deepEqual(calls.load.at(-1), ['A-0', 'thumbnail', true])
  assert.equal(window.snapshot()[1].asset.uri, healthy.asset.uri)
  assert.equal(window.snapshot()[1].slotId, healthy.slotId)
  window.reportPresentation(failed.slotId, failed.asset.assetRequestId, false)
  assert.equal(window.snapshot()[0].asset.phase, 'decoding')
  window.close()
})

test('new unit and invalid ranges cannot retain or create unintended leases', async () => {
  const { window, unit, calls } = setup()
  window.setRange(unit, 0, 0); await tick()
  for (const [a, b] of [[-1, 0], [0, 40], [3, 2], [NaN, 2], [1.2, 3]]) window.setRange(unit, a, b)
  assert.equal(calls.load.length, 2)
  const other = unit.copy(); other.key.unit = 'B'
  window.setRange(other, 0, 0); await tick()
  assert.equal(calls.release.length, 2)
  assert.ok(window.snapshot().every(f => f.asset.page.unit.unit === 'B'))
  window.close(); window.setRange(unit, 0, 0); await tick()
  assert.equal(calls.load.length, 4)
})

test('browsing auxiliary thumbnails cannot select or observe a reading page', async () => {
  const { unit, catalog, assets } = setup()
  const reader = new ReaderPagedSession(catalog, assets)
  await reader.open(unit.key, 2); await tick()
  const before = reader.snapshot()
  const window = reader.createThumbnailWindow()
  window.setRange(reader.snapshot().unit, 30, 32); await tick()
  window.snapshot().forEach(f => window.reportPresentation(f.slotId, f.asset.assetRequestId, true, 200, 300))
  assert.equal(reader.snapshot().navigationRevision, before.navigationRevision)
  assert.equal(reader.snapshot().anchor.sourceIndexHint, 2)
  assert.equal(reader.snapshot().observedAnchor, null)
  window.close(); reader.close()
})
