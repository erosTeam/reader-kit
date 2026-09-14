const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset, ReaderAssetNotice, ReaderSession } = load('ReaderSession')
const { ReaderPagedSession } = load('ReaderPagedSession')

test('suppressed assets never become observed images and reload only after their exact host action succeeds', async () => {
  const key = new ReaderUnitKey('host', 'work', 'unit')
  let blocked = true
  let actions = 0
  const catalog = {
    async open(target) { return new ReaderUnit(target, 'Unit', 1) },
    async page(unit, index) { return new ReaderPage(unit.key, 'page-0', index) },
    adjacent() { return null },
  }
  const assets = {
    cancellationMode: 'consumer-only',
    async load() {
      const asset = new ReaderAsset('file:///cache/page.jpg')
      if (blocked) {
        asset.setNotice(new ReaderAssetNotice('blocked', 'Blocked', 'Hidden by host policy', 'Allow', asset.uri), async () => {
          actions++
          blocked = false
          return true
        })
      }
      return asset
    },
  }
  const session = new ReaderSession(catalog, assets)
  session.setViewportActive(true)
  await session.open(key)
  const suppressed = session.snapshot()
  assert.equal(suppressed.phase, 'suppressed')
  assert.equal(suppressed.notice.id, 'blocked')
  session.reportPresentation(suppressed.assetRequestId, true)
  session.reportVisiblePosition(suppressed.assetRequestId, 'page-0', 0.5, 0.5)
  assert.equal(session.snapshot().phase, 'suppressed')
  assert.equal(session.snapshot().presentedAnchor, null)
  assert.equal(await session.resolveNotice(suppressed.assetRequestId, 'stale'), false)
  assert.equal(actions, 0)
  assert.equal(await session.resolveNotice(suppressed.assetRequestId, 'blocked'), true)
  assert.equal(actions, 1)
  const ready = session.snapshot()
  assert.equal(ready.phase, 'decoding')
  assert.equal(ready.notice, null)
  session.reportPresentation(ready.assetRequestId, true)
  session.reportVisiblePosition(ready.assetRequestId, 'page-0', 0.5, 0.5)
  assert.equal(session.snapshot().phase, 'displayed')
  assert.equal(session.snapshot().presentedAnchor.sourceIndexHint, 0)
  session.close()
})

test('a failed host notice action keeps the current suppression in place', async () => {
  const key = new ReaderUnitKey('host', 'work', 'unit')
  const catalog = {
    async open(target) { return new ReaderUnit(target, 'Unit', 1) },
    async page(unit, index) { return new ReaderPage(unit.key, 'page-0', index) },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only', async load() {
    const asset = new ReaderAsset('file:///cache/page.jpg')
    asset.setNotice(new ReaderAssetNotice('blocked', 'Blocked', 'Hidden', 'Allow'), async () => false)
    return asset
  } }
  const session = new ReaderSession(catalog, assets)
  await session.open(key)
  const snapshot = session.snapshot()
  assert.equal(await session.resolveNotice(snapshot.assetRequestId, 'blocked'), false)
  assert.equal(session.snapshot().phase, 'suppressed')
  session.close()
})

test('paged notice recovery rejects stale topology and navigation before touching the provider action', async () => {
  const key = new ReaderUnitKey('host', 'work', 'unit')
  let blocked = true
  let actions = 0
  const catalog = {
    async open(target) { return new ReaderUnit(target, 'Unit', 1) },
    async page(unit, index) { return new ReaderPage(unit.key, 'page-0', index) },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only', async load() {
    const asset = new ReaderAsset('file:///cache/page.jpg')
    if (blocked) asset.setNotice(new ReaderAssetNotice('blocked', 'Blocked', 'Hidden', 'Allow'), async () => {
      actions++
      blocked = false
      return true
    })
    return asset
  } }
  const session = new ReaderPagedSession(catalog, assets)
  session.setViewportActive(true)
  await session.open(key)
  await new Promise(resolve => setImmediate(resolve))
  const state = session.snapshot()
  const frame = state.frames[0]
  const itemKey = state.displayKeys[state.displayIndex]
  assert.equal(frame.asset.phase, 'suppressed')
  assert.equal(await session.resolveNoticeItem(state.topologyRevision + 1, state.navigationRevision,
    itemKey, frame.slotId, frame.asset.assetRequestId, 'blocked'), false)
  assert.equal(await session.resolveNoticeItem(state.topologyRevision, state.navigationRevision + 1,
    itemKey, frame.slotId, frame.asset.assetRequestId, 'blocked'), false)
  assert.equal(actions, 0)
  assert.equal(await session.resolveNoticeItem(state.topologyRevision, state.navigationRevision,
    itemKey, frame.slotId, frame.asset.assetRequestId, 'blocked'), true)
  assert.equal(actions, 1)
  assert.equal(session.snapshot().frames[0].asset.phase, 'decoding')
  session.close()
})
