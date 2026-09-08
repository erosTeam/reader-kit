const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const { ReaderDisplayPolicy } = load('ReaderDisplayMap')
const tick = () => new Promise(resolve => setImmediate(resolve))

function setup({ count = 5, wide = [], fail = [], deferred = false } = {}) {
  const key = new ReaderUnitKey('source', 'work', 'A')
  const calls = { open: [], load: [], release: [], pending: [] }
  const catalog = {
    async open(target) { calls.open.push(target.copy()); return new ReaderUnit(target, target.unit, count) },
    async page(unit, index) {
      const page = new ReaderPage(unit.key, `${unit.key.unit}-${index}`, index)
      page.width = wide.includes(index) ? 1800 : 800
      page.height = 1200
      page.thumbnail.width = 200; page.thumbnail.height = 100
      return page
    },
    adjacent(unit, direction) {
      return direction === 'next' && unit.key.unit === 'A' ? new ReaderUnitKey('source', 'work', 'B') : null
    },
  }
  const assets = {
    cancellationMode: 'consumer-only',
    async load(page, kind, cancellation, force) {
      calls.load.push([page.key, kind, force])
      if (fail.includes(page.sourceIndex) && !force) throw Error('sample failure')
      const asset = new ReaderAsset(`${kind}:${page.key}`, () => calls.release.push(`${kind}:${page.key}`))
      if (deferred) return new Promise(resolve => calls.pending.push(() => resolve(asset)))
      return asset
    },
  }
  const session = new ReaderPagedSession(catalog, assets)
  session.setViewportActive(true)
  return { session, key, calls, catalog }
}
function policy(changes) { return Object.assign(new ReaderDisplayPolicy(), changes) }
function decode(session, frame, width = 0, height = 0) {
  session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true, width, height)
}

test('one-page spread shift uses logical start, preserves overlap and re-pairs both directions', async () => {
  for (const direction of ['ltr', 'rtl']) {
    const { session, key, calls } = setup({ count: 7 })
    session.setPolicy(policy({ layout: 'spread', direction }))
    await session.open(key, 1); await tick()
    const before = session.snapshot()
    const overlap = before.frames.find(f => f.part.sourceIndex === 1)
    assert.equal(session.shiftSpread(key, before.topologyRevision, before.navigationRevision), true)
    await tick()
    let after = session.snapshot()
    assert.equal(after.anchor.sourceIndexHint, 1)
    assert.equal(after.policy.firstPageAlone, true)
    assert.deepEqual(after.frames.map(f => f.part.sourceIndex), direction === 'rtl' ? [2, 1] : [1, 2])
    assert.equal(after.frames.find(f => f.part.sourceIndex === 1).slotId, overlap.slotId)
    assert.equal(after.observedAnchor, null)
    assert.equal(calls.open.length, 1)
    assert.equal(session.shiftSpread(key, before.topologyRevision, before.navigationRevision), false)
    session.move('next'); await tick()
    assert.equal(session.snapshot().anchor.sourceIndexHint, 3)
    session.move('previous'); await tick()
    after = session.snapshot()
    assert.equal(session.shiftSpread(key, after.topologyRevision, after.navigationRevision), true)
    await tick()
    assert.equal(session.snapshot().policy.firstPageAlone, false)
    assert.equal(session.snapshot().anchor.sourceIndexHint, 2)
    session.close()
  }
})

test('spread shift accepts final pair to singleton but never crosses unit or non-spread modes', async () => {
  const { session, key, calls } = setup({ count: 4 })
  await session.open(key); await tick()
  let state = session.snapshot()
  assert.equal(state.canShiftSpread, false)
  assert.equal(session.shiftSpread(key, state.topologyRevision, state.navigationRevision), false)
  session.setPolicy(policy({ layout: 'spread', firstPageAlone: true })); await tick()
  state = session.snapshot()
  assert.equal(session.shiftSpread(key, state.topologyRevision, state.navigationRevision), true)
  assert.equal(session.snapshot().anchor.sourceIndexHint, 1)
  session.setPolicy(policy({ layout: 'spread' }))
  session.seekSource(2, key, session.snapshot().navigationRevision); await tick()
  state = session.snapshot()
  assert.equal(state.canShiftSpread, true)
  session.setViewportActive(false)
  assert.equal(session.shiftSpread(key, state.topologyRevision, state.navigationRevision), false)
  session.setViewportActive(true)
  assert.equal(session.shiftSpread(new ReaderUnitKey('source', 'work', 'B'), state.topologyRevision, state.navigationRevision), false)
  assert.equal(session.shiftSpread(key, state.topologyRevision, state.navigationRevision), true)
  await tick(); state = session.snapshot()
  assert.equal(state.anchor.sourceIndexHint, 3)
  assert.deepEqual(state.frames.map(f => f.part.sourceIndex), [3])
  assert.equal(state.canShiftSpread, false)
  assert.equal(session.shiftSpread(key, state.topologyRevision, state.navigationRevision), false)
  assert.equal(calls.open.length, 1)
  session.close()
})

test('source seek is not a display index and does not reopen the host catalog', async () => {
  const { session, key, calls } = setup({ count: 8 })
  session.setPolicy(policy({ layout: 'spread', firstPageAlone: true }))
  await session.open(key); await tick()
  assert.equal(session.seekSource(4, key, session.snapshot().navigationRevision), true)
  await tick()
  const state = session.snapshot()
  assert.equal(state.anchor.sourceIndexHint, 4)
  assert.equal(state.displayIndex, 2)
  assert.deepEqual(state.frames.map(frame => frame.part.sourceIndex), [3, 4])
  assert.equal(calls.open.length, 1)
  assert.equal(state.observedAnchor, null)
  session.close()
})

test('source seek starts on the direction-appropriate wide half even when already on the same source', async () => {
  const { session, key } = setup({ wide: [0] })
  session.setPolicy(policy({ splitWidePages: true }))
  await session.open(key); await tick()
  session.move('next')
  assert.equal(session.snapshot().anchor.fragment, 'right')
  assert.equal(session.seekSource(0, key, session.snapshot().navigationRevision), true)
  assert.equal(session.snapshot().anchor.fragment, 'left')
  session.setPolicy(policy({ splitWidePages: true, direction: 'rtl' }))
  assert.equal(session.seekSource(0, key, session.snapshot().navigationRevision), true)
  assert.equal(session.snapshot().anchor.fragment, 'right')
  session.close()
})

test('source seek rejects invalid indices and stale navigation or unit tokens without mutation', async () => {
  const { session, key } = setup()
  await session.open(key); await tick()
  const before = session.snapshot()
  for (const index of [-1, 5, 0.5, NaN, Infinity]) {
    assert.equal(session.seekSource(index, key, before.navigationRevision), false)
  }
  assert.equal(session.snapshot().navigationRevision, before.navigationRevision)
  session.move('next')
  assert.equal(session.seekSource(3, key, before.navigationRevision), false)
  await session.switchUnit('next'); await tick()
  assert.equal(session.seekSource(3, key, session.snapshot().navigationRevision), false)
  assert.equal(session.snapshot().anchor.sourceIndexHint, 0)
  session.close()
  assert.equal(session.seekSource(0, session.snapshot().unit.key, session.snapshot().navigationRevision), false)
})

test('seeking the current continuous source resets its row anchor without fabricating observation', async () => {
  const { session, key } = setup()
  session.setPolicy(policy({ layout: 'continuous' }))
  await session.open(key); await tick()
  let state = session.snapshot()
  session.setContinuousRange(0, 0, state.topologyRevision, state.navigationRevision)
  const frame = state.frames[0]
  decode(session, frame)
  state = session.snapshot()
  assert.equal(session.reportContinuousVisible(state.topologyRevision, state.navigationRevision,
    state.displayKeys[0], frame.slotId, frame.asset.assetRequestId, 0.5, 0.35), true)
  assert.equal(session.seekSource(0, key, state.navigationRevision), true)
  const after = session.snapshot()
  assert.equal(after.anchor.y, 0)
  assert.equal(after.observedAnchor.y, 0.35)
  assert.notEqual(after.navigationRevision, state.navigationRevision)
  session.close()
})

test('spread owns two assets but opens host catalog only once; RTL changes visual order, not anchor', async () => {
  const { session, key, calls } = setup()
  session.setPolicy(policy({ layout: 'spread' }))
  await session.open(key, 1); await tick()
  assert.equal(calls.open.length, 1)
  assert.deepEqual(calls.load.map(call => call[0]), ['A-0', 'A-1'])
  let state = session.snapshot()
  assert.equal(state.anchor.pageKey, 'A-1')
  assert.equal(state.observedAnchor, null)
  decode(session, state.frames[0])
  assert.equal(session.reportVisible(state.selectionId, state.frames[0].slotId, state.frames[0].asset.assetRequestId, state.frames[0].part.fragment), false)
  decode(session, state.frames[1])
  assert.equal(session.reportVisible(state.selectionId, state.frames[1].slotId, state.frames[1].asset.assetRequestId, state.frames[1].part.fragment), true)
  session.setPolicy(policy({ layout: 'spread', direction: 'rtl' }))
  state = session.snapshot()
  assert.deepEqual(state.frames.map(frame => frame.part.sourceIndex), [1, 0])
  assert.equal(state.anchor.pageKey, 'A-1')
  assert.equal(calls.load.length, 2)
  session.setPolicy(policy({ layout: 'single' }))
  assert.equal(session.snapshot().frames[0].part.sourceIndex, 1)
  assert.deepEqual(calls.release, ['original:A-0'])
  session.close()
})

test('wide halves navigate without downloading again; collapse and RTL restore physical half', async () => {
  const { session, key, calls } = setup({ wide: [0] })
  session.setPolicy(policy({ splitWidePages: true }))
  await session.open(key); await tick()
  let state = session.snapshot()
  assert.equal(state.frames[0].part.fragment, 'left')
  decode(session, state.frames[0])
  session.move('next')
  state = session.snapshot()
  assert.equal(state.frames[0].part.fragment, 'right')
  assert.equal(state.anchor.x, 0.75)
  assert.equal(calls.load.length, 1)
  session.setPolicy(policy({ splitWidePages: false }))
  assert.equal(session.snapshot().frames[0].part.fragment, 'whole')
  session.setPolicy(policy({ splitWidePages: true, direction: 'rtl' }))
  assert.equal(session.snapshot().frames[0].part.fragment, 'right')
  assert.equal(session.snapshot().displayIndex, 0)
  session.move('next')
  assert.equal(session.snapshot().frames[0].part.fragment, 'left')
  assert.equal(calls.load.length, 1)
  session.close()
})

test('native original metrics refine unknown dimensions, thumbnails never affect split or page aspect', async () => {
  const { session, key, catalog } = setup()
  const originalPage = catalog.page
  catalog.page = async (...args) => { const page = await originalPage(...args); page.width = 0; page.height = 0; return page }
  session.setPolicy(policy({ splitWidePages: true }))
  await session.open(key); await tick()
  decode(session, session.snapshot().frames[0], 1800, 1200)
  assert.equal(session.snapshot().frames[0].part.fragment, 'left')
  const oldSelection = session.snapshot().selectionId
  session.setAssetKind('thumbnail'); await tick()
  decode(session, session.snapshot().frames[0], 200, 100)
  const state = session.snapshot()
  assert.equal(state.frames[0].asset.page.width, 1800)
  assert.equal(state.frames[0].asset.page.height, 1200)
  assert.equal(session.reportVisible(oldSelection, state.frames[0].slotId, state.frames[0].asset.assetRequestId, state.frames[0].part.fragment), false)
  assert.equal(session.reportVisible(state.selectionId, state.frames[0].slotId, state.frames[0].asset.assetRequestId, state.frames[0].part.fragment), false)
  session.close()
})

test('late original from superseded spread is released and cannot become current pixels', async () => {
  const { session, key, calls } = setup({ deferred: true })
  session.setPolicy(policy({ layout: 'spread' }))
  await session.open(key); await tick()
  session.move('next'); await tick()
  calls.pending.forEach(resolve => resolve()); await tick()
  assert.deepEqual(calls.release.sort(), ['original:A-0', 'original:A-1'])
  assert.deepEqual(session.snapshot().frames.map(frame => frame.asset.uri), ['original:A-2', 'original:A-3'])
  session.close()
  assert.equal(calls.release.length, 4)
})

test('failed sibling retries independently without releasing successful original', async () => {
  const { session, key, calls } = setup({ fail: [1] })
  session.setPolicy(policy({ layout: 'spread' }))
  await session.open(key); await tick()
  const first = session.snapshot().frames[0]
  decode(session, first)
  assert.equal(session.snapshot().frames[1].asset.phase, 'failed')
  await session.retry(); await tick()
  assert.equal(session.snapshot().frames[0].slotId, first.slotId)
  assert.equal(session.snapshot().frames[0].asset.phase, 'displayed')
  assert.equal(session.snapshot().frames[1].asset.phase, 'decoding')
  assert.equal(calls.release.length, 0)
  assert.deepEqual(calls.load.at(-1), ['A-1', 'original', true])
  session.close()
})

test('visibility requires current layout revision, decoded selected original and foreground', async () => {
  const { session, key } = setup({ wide: [0] })
  session.setPolicy(policy({ splitWidePages: true }))
  await session.open(key); await tick()
  const before = session.snapshot()
  const frame = before.frames[0]
  assert.equal(session.reportVisible(before.selectionId, frame.slotId, frame.asset.assetRequestId, frame.part.fragment), false)
  decode(session, frame)
  session.move('next')
  assert.equal(session.reportVisible(before.selectionId, frame.slotId, frame.asset.assetRequestId, frame.part.fragment), false)
  const after = session.snapshot()
  session.setViewportActive(false)
  assert.equal(session.reportVisible(after.selectionId, frame.slotId, frame.asset.assetRequestId, 'right'), false)
  session.setViewportActive(true)
  assert.equal(session.reportVisible(after.selectionId, frame.slotId, frame.asset.assetRequestId, 'right'), true)
  assert.equal(session.snapshot().observedAnchor.fragment, 'right')
  const copy = session.snapshot(); copy.anchor.pageKey = 'mutated'; copy.frames[0].asset.page.width = -5
  assert.equal(session.snapshot().anchor.pageKey, 'A-0')
  assert.equal(session.snapshot().frames[0].asset.page.width, 1800)
  session.close()
  assert.equal(session.reportVisible(after.selectionId, frame.slotId, frame.asset.assetRequestId, 'right'), false)
})

test('failed next unit retains old pixels/observed anchor; retry commits only new valid catalog', async () => {
  const { session, key, catalog } = setup()
  await session.open(key); await tick()
  const a = session.snapshot(); decode(session, a.frames[0])
  session.reportVisible(a.selectionId, a.frames[0].slotId, a.frames[0].asset.assetRequestId, a.frames[0].part.fragment)
  const originalOpen = catalog.open
  catalog.open = async key => { if (key.unit === 'B') throw Error('offline'); return originalOpen(key) }
  await session.switchUnit('next')
  assert.equal(session.snapshot().unit.key.unit, 'A')
  assert.equal(session.snapshot().frames[0].asset.uri, 'original:A-0')
  assert.equal(session.snapshot().phase, 'failed')
  assert.equal(session.reportVisible(session.snapshot().selectionId, a.frames[0].slotId, a.frames[0].asset.assetRequestId, a.frames[0].part.fragment), false)
  catalog.open = originalOpen
  await session.retry(); await tick()
  assert.equal(session.snapshot().unit.key.unit, 'B')
  assert.equal(session.snapshot().observedAnchor.unit.unit, 'A')
  session.close()
})

test('final cover-aligned spread stays in unit; invalid ratio policy is rejected', async () => {
  const { session, key } = setup({ count: 4 })
  assert.throws(() => session.setPolicy(policy({ widePageRatio: 0 })), /unsupported/)
  session.setPolicy(policy({ layout: 'spread', firstPageAlone: true }))
  await session.open(key, 3); await tick()
  assert.equal(session.snapshot().displayCount, 3)
  assert.deepEqual(session.snapshot().frames.map(frame => frame.part.sourceIndex), [3])
  session.move('next')
  assert.equal(session.snapshot().unit.key.unit, 'A')
  assert.equal(session.snapshot().anchor.sourceIndexHint, 3)
  session.close()
})

test('current remounted half decode failure is retryable; retired half cannot fail or observe the new side', async () => {
  const { session, key, calls } = setup({ wide: [0] })
  session.setPolicy(policy({ splitWidePages: true }))
  await session.open(key); await tick()
  const left = session.snapshot(); decode(session, left.frames[0])
  session.move('next')
  const right = session.snapshot(), frame = right.frames[0]
  session.reportRenderFailure(left.selectionId, frame.slotId, frame.asset.assetRequestId, 'left')
  session.reportRenderFailure(right.selectionId, frame.slotId, frame.asset.assetRequestId, 'left')
  assert.equal(session.snapshot().frames[0].asset.phase, 'displayed')
  assert.equal(session.reportVisible(right.selectionId, frame.slotId, frame.asset.assetRequestId, 'left'), false)
  session.reportRenderFailure(right.selectionId, frame.slotId, frame.asset.assetRequestId, 'right')
  assert.equal(session.snapshot().frames[0].asset.error, 'reader_decode_failed')
  await session.retry(); await tick()
  assert.equal(session.snapshot().frames[0].asset.phase, 'decoding')
  assert.equal(session.snapshot().frames[0].part.fragment, 'right')
  assert.deepEqual(calls.load.at(-1), ['A-0', 'original', true])
  session.close()
})

test('native pager window owns at most six spread assets and reuses the outgoing/current neighbor', async () => {
  const { session, key, calls } = setup({ count: 10 })
  session.setPolicy(policy({ layout: 'spread' }))
  session.setNeighborPreload(true)
  await session.open(key, 4); await tick()
  let state = session.snapshot()
  assert.equal(calls.open.length, 1)
  assert.equal(state.window.length, 3)
  assert.deepEqual(calls.load.map(c => c[0]), ['A-4', 'A-5', 'A-2', 'A-3', 'A-6', 'A-7'])
  const next = state.window.find(item => item.index === 3)
  const nextSlots = next.frames.map(frame => frame.slotId)
  next.frames.forEach(frame => decode(session, frame))
  assert.equal(session.selectDisplay(3, state.topologyRevision, state.navigationRevision), true)
  await tick(); state = session.snapshot()
  assert.deepEqual(state.frames.map(frame => frame.slotId), nextSlots)
  assert.deepEqual(state.frames.map(frame => frame.asset.phase), ['displayed', 'displayed'])
  assert.deepEqual(calls.release.sort(), ['original:A-2', 'original:A-3'])
  assert.equal(new Set(state.window.flatMap(item => item.frames.map(frame => frame.slotId))).size, 6)
  session.close()
  assert.equal(calls.release.length, 8)
})

test('prefetched decoded page cannot report selection; returning to it reuses the asset', async () => {
  const { session, key, calls } = setup()
  session.setNeighborPreload(true)
  await session.open(key, 1); await tick()
  const state = session.snapshot(), next = state.window.find(item => item.index === 2).frames[0]
  decode(session, next)
  assert.equal(session.reportVisible(state.selectionId, next.slotId, next.asset.assetRequestId, 'whole'), false)
  assert.equal(session.snapshot().observedAnchor, null)
  session.move('next'); await tick()
  const selected = session.snapshot()
  assert.equal(selected.frames[0].slotId, next.slotId)
  assert.equal(session.reportVisible(selected.selectionId, next.slotId, next.asset.assetRequestId, 'whole'), true)
  session.move('previous'); await tick()
  session.move('next'); await tick()
  assert.equal(calls.load.filter(c => c[0] === 'A-2').length, 1)
  assert.equal(session.snapshot().observedAnchor.sourceIndexHint, 2)
  session.close()
})

test('native delayed index is fenced by topology and navigation, not asset decode updates', async () => {
  const { session, key } = setup()
  session.setNeighborPreload(true)
  await session.open(key, 1); await tick()
  const initial = session.snapshot()
  initial.window.forEach(item => item.frames.forEach(frame => decode(session, frame)))
  assert.equal(session.selectDisplay(2, initial.topologyRevision, initial.navigationRevision), true)
  assert.equal(session.selectDisplay(0, initial.topologyRevision, initial.navigationRevision), false)
  const beforePolicy = session.snapshot()
  session.setPolicy(policy({ direction: 'rtl' }))
  assert.equal(session.selectDisplay(0, beforePolicy.topologyRevision, session.snapshot().navigationRevision), false)
  const state = session.snapshot()
  assert.equal(session.selectDisplay(-1, state.topologyRevision, state.navigationRevision), false)
  assert.equal(session.selectDisplay(99, state.topologyRevision, state.navigationRevision), false)
  assert.equal(session.selectDisplay(1.5, state.topologyRevision, state.navigationRevision), false)
  assert.equal(session.snapshot().anchor.sourceIndexHint, 2)
  session.close()
})

test('late neighbor topology preserves the selected original and invalidates retired index maps', async () => {
  const { session, key, catalog } = setup()
  const originalPage = catalog.page
  catalog.page = async (...args) => { const page = await originalPage(...args); page.width = 0; page.height = 0; return page }
  session.setPolicy(policy({ splitWidePages: true }))
  session.setNeighborPreload(true)
  await session.open(key, 2); await tick()
  const state = session.snapshot(), previous = state.window.find(item => item.index === 1).frames[0]
  decode(session, previous, 1800, 1200)
  const refined = session.snapshot()
  assert.equal(refined.anchor.pageKey, 'A-2')
  assert.equal(refined.displayIndex, 3)
  assert.ok(refined.topologyRevision > state.topologyRevision)
  assert.equal(refined.navigationRevision, state.navigationRevision)
  assert.equal(session.selectDisplay(3, state.topologyRevision, state.navigationRevision), false)
  session.close()
})

test('cached decode failures are scoped to rendered item identity; retry concerns only the selected item', async () => {
  const { session, key, calls } = setup({ fail: [0, 2] })
  session.setNeighborPreload(true)
  await session.open(key, 1); await tick()
  let state = session.snapshot()
  assert.equal(state.frames[0].asset.phase, 'decoding')
  await session.retry(); await tick()
  assert.equal(calls.load.length, 3)
  decode(session, state.frames[0])
  const frame = state.frames[0]
  session.reportCachedRenderFailure(state.topologyRevision, '0:whole', frame.slotId, frame.asset.assetRequestId, 'whole')
  assert.equal(session.snapshot().frames[0].asset.phase, 'displayed')
  session.reportCachedRenderFailure(state.topologyRevision, '1:whole', frame.slotId, frame.asset.assetRequestId, 'whole')
  assert.equal(session.snapshot().frames[0].asset.phase, 'failed')
  await session.retry(); await tick()
  assert.deepEqual(calls.load.at(-1), ['A-1', 'original', true])
  state = session.snapshot()
  assert.equal(state.window.find(item => item.index === 2).frames[0].asset.phase, 'failed')
  session.close()
})

test('window projections are detached and disabling preload releases only neighbors', async () => {
  const { session, key, calls } = setup()
  session.setNeighborPreload(true)
  await session.open(key, 2); await tick()
  const state = session.snapshot(), item = state.forItem('1:whole')
  assert.equal(item.frames[0].part.sourceIndex, 1)
  item.frames[0].asset.page.width = -20
  state.displayKeys[0] = 'changed'
  assert.equal(session.snapshot().displayKeys[0], '0:whole')
  assert.equal(session.snapshot().window.find(w => w.index === 1).frames[0].asset.page.width, 800)
  session.setNeighborPreload(false)
  assert.deepEqual(calls.release.sort(), ['original:A-1', 'original:A-3'])
  assert.equal(session.snapshot().frames[0].slotId, state.frames[0].slotId)
  session.close()
})

test('continuous demand is the visible range plus neighbors, not the entire catalog', async () => {
  const { session, key, calls } = setup({ count: 30, wide: [2] })
  session.setPolicy(policy({ layout: 'continuous', splitWidePages: true }))
  session.setNeighborPreload(true)
  await session.open(key, 2); await tick()
  let s = session.snapshot()
  assert.equal(s.displayCount, 30)
  assert.equal(session.setContinuousRange(2, 5, s.topologyRevision, s.navigationRevision), true)
  await tick(); s = session.snapshot()
  assert.deepEqual(s.window.map(w => w.index), [2, 3, 4, 5, 1, 6])
  assert.equal(calls.load.length, 6)
  assert.equal(calls.open.length, 1)
  assert.equal(s.observedAnchor, null)
  const slot = s.window.find(w => w.index === 5).frames[0].slotId
  assert.equal(session.setContinuousRange(5, 5, s.topologyRevision, s.navigationRevision), true)
  await tick(); s = session.snapshot()
  assert.deepEqual(s.window.map(w => w.index), [5, 4, 6])
  assert.equal(s.frames[0].slotId, slot)
  assert.deepEqual(calls.release.sort(), ['original:A-1', 'original:A-2', 'original:A-3'])
  assert.equal(s.pageMetadata.find(p => p.sourceIndex === 2).width, 1800)
  s.pageMetadata[0].width = -5
  assert.ok(session.snapshot().pageMetadata.every(p => p.width > 0))
  session.close()
})

test('continuous observations require decoded active first-visible original and valid point', async () => {
  const { session, key } = setup()
  session.setPolicy(policy({ layout: 'continuous' })); session.setNeighborPreload(true)
  await session.open(key); await tick()
  let s = session.snapshot()
  session.setContinuousRange(0, 1, s.topologyRevision, s.navigationRevision)
  await tick(); s = session.snapshot()
  const current = s.frames[0], next = s.window.find(w => w.index === 1).frames[0]
  const observe = (f, index, y) => session.reportContinuousVisible(s.topologyRevision, s.navigationRevision,
    `${index}:whole`, f.slotId, f.asset.assetRequestId, 0.5, y)
  assert.equal(observe(current, 0, 0.25), false)
  decode(session, current); decode(session, next)
  assert.equal(session.snapshot().observedAnchor, null)
  assert.equal(observe(next, 1, 0), false)
  for (const y of [-0.1, 1.1, NaN, Infinity]) assert.equal(observe(current, 0, y), false)
  assert.equal(session.reportVisible(s.selectionId, current.slotId, current.asset.assetRequestId, 'whole'), false)
  assert.equal(observe(current, 0, 0.25), true)
  assert.equal(session.snapshot().anchor.y, 0.25)
  assert.equal(session.snapshot().observedAnchor.y, 0.25)
  assert.equal(observe(current, 0, 0.75), true)
  session.setViewportActive(false)
  assert.equal(observe(current, 0, 0.9), false)
  assert.equal(session.snapshot().observedAnchor.y, 0.75)
  session.close()
})

test('old continuous demand and geometry cannot undo a navigation or mode command', async () => {
  const { session, key } = setup()
  session.setPolicy(policy({ layout: 'continuous' }))
  await session.open(key); await tick()
  let s = session.snapshot(); session.setContinuousRange(0, 0, s.topologyRevision, s.navigationRevision)
  decode(session, s.frames[0]); s = session.snapshot()
  const f = s.frames[0]
  session.move('next'); await tick()
  assert.equal(session.setContinuousRange(0, 0, s.topologyRevision, s.navigationRevision), false)
  assert.equal(session.reportContinuousVisible(s.topologyRevision, s.navigationRevision,
    '0:whole', f.slotId, f.asset.assetRequestId, 0.5, 0.4), false)
  assert.equal(session.snapshot().anchor.sourceIndexHint, 1)
  const newer = session.snapshot()
  session.setPolicy(policy({ layout: 'single' }))
  assert.equal(session.setContinuousRange(1, 1, newer.topologyRevision, newer.navigationRevision), false)
  session.close()
})

test('continuous normalized original anchor survives thumbnail and layout transitions', async () => {
  const { session, key } = setup()
  session.setPolicy(policy({ layout: 'continuous' }))
  await session.open(key); await tick()
  let s = session.snapshot();session.setContinuousRange(0, 0, s.topologyRevision, s.navigationRevision)
  decode(session, s.frames[0]);s = session.snapshot()
  assert.equal(session.reportContinuousVisible(s.topologyRevision, s.navigationRevision,
    '0:whole', s.frames[0].slotId, s.frames[0].asset.assetRequestId, 0.5, 0.6), true)
  session.setAssetKind('thumbnail');await tick()
  s = session.snapshot();session.setContinuousRange(0, 0, s.topologyRevision, s.navigationRevision)
  decode(session, s.frames[0]);s = session.snapshot()
  assert.equal(session.reportContinuousVisible(s.topologyRevision, s.navigationRevision,
    '0:whole', s.frames[0].slotId, s.frames[0].asset.assetRequestId, 0.5, 0), false)
  assert.equal(session.snapshot().observedAnchor.y, 0.6)
  session.setAssetKind('original'); await tick()
  assert.equal(session.snapshot().anchor.y, 0.6)
  session.setPolicy(policy({ layout: 'spread' }))
  assert.equal(session.snapshot().anchor.y, 0.6)
  session.setPolicy(policy({ layout: 'continuous' }))
  assert.equal(session.snapshot().anchor.y, 0.6)
  session.close()
})

test('continuous range rejects invalid or inactive demand without acquiring resources', async () => {
  const { session, key, calls } = setup()
  session.setPolicy(policy({ layout: 'continuous' }))
  await session.open(key); await tick()
  const s = session.snapshot()
  for (const [start, end] of [[-1, 0], [2, 1], [0, 5], [0.5, 1], [0, Infinity]]) {
    assert.equal(session.setContinuousRange(start, end, s.topologyRevision, s.navigationRevision), false)
  }
  session.setViewportActive(false)
  assert.equal(session.setContinuousRange(1, 2, s.topologyRevision, s.navigationRevision), false)
  assert.equal(calls.load.length, 1)
  assert.equal(session.snapshot().anchor.sourceIndexHint, 0)
  session.close()
})

test('visible neighbor failure retries exactly that request without changing the continuous anchor', async () => {
  const { session, key, calls } = setup({ fail: [1] })
  session.setPolicy(policy({ layout: 'continuous' })); session.setNeighborPreload(true)
  await session.open(key); await tick()
  let s = session.snapshot(); session.setContinuousRange(0, 1, s.topologyRevision, s.navigationRevision)
  decode(session, s.frames[0]); s = session.snapshot()
  session.reportContinuousVisible(s.topologyRevision, s.navigationRevision, '0:whole',
    s.frames[0].slotId, s.frames[0].asset.assetRequestId, 0.5, 0.8)
  s = session.snapshot()
  const failed = s.window.find(w => w.index === 1).frames[0]
  assert.equal(failed.asset.phase, 'failed'); assert.equal(failed.asset.assetRequestId, 0)
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId), true)
  const recovered = session.snapshot()
  assert.equal(recovered.displayIndex, 0)
  assert.equal(recovered.observedAnchor.y, 0.8)
  assert.equal(recovered.frames[0].slotId, s.frames[0].slotId)
  assert.equal(recovered.frames[0].asset.phase, 'displayed')
  assert.equal(recovered.window.find(w => w.index === 1).frames[0].asset.phase, 'decoding')
  assert.deepEqual(calls.load.filter(c => c[2]), [['A-1', 'original', true]])
  assert.equal(calls.release.length, 0); assert.equal(calls.open.length, 1)
  session.close()
})

test('item retry rejects cached-only, wrong, duplicate, retired and inactive requests', async () => {
  const { session, key, calls } = setup({ fail: [1] })
  session.setPolicy(policy({ layout: 'continuous' })); session.setNeighborPreload(true)
  await session.open(key); await tick()
  let s = session.snapshot(); session.setContinuousRange(0, 0, s.topologyRevision, s.navigationRevision)
  let failed = s.window.find(w => w.index === 1).frames[0]
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId), false)
  session.setContinuousRange(0, 1, s.topologyRevision, s.navigationRevision); await tick()
  s = session.snapshot(); failed = s.window.find(w => w.index === 1).frames[0]
  for (const args of [[s.topologyRevision + 1, '1:whole', failed.slotId, failed.asset.requestId],
    [s.topologyRevision, '0:whole', failed.slotId, failed.asset.requestId],
    [s.topologyRevision, '1:whole', failed.slotId + 100, failed.asset.requestId],
    [s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId + 100]]) {
    assert.equal(await session.retryItem(...args), false)
  }
  session.setViewportActive(false)
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId), false)
  session.setViewportActive(true)
  const retry = session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId)
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId), false)
  assert.equal(await retry, true)
  const current = session.snapshot().window.find(w => w.index === 1).frames[0]
  decode(session, current)
  session.reportCachedRenderFailure(s.topologyRevision, '1:whole', current.slotId, current.asset.assetRequestId, 'whole')
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', failed.slotId, failed.asset.requestId), false)
  session.move('next'); session.move('next'); session.move('next'); await tick()
  assert.equal(await session.retryItem(s.topologyRevision, '1:whole', current.slotId, current.asset.requestId), false)
  assert.equal(calls.load.filter(c => c[2]).length, 1)
  session.close()
})

test('item retry can target one failed spread pane and leaves the other failure untouched', async () => {
  const { session, key, calls } = setup({ fail: [0, 1] })
  session.setPolicy(policy({ layout: 'spread', direction: 'rtl' }))
  await session.open(key); await tick()
  const s = session.snapshot(), right = s.frames.find(f => f.part.sourceIndex === 0)
  assert.equal(await session.retryItem(s.topologyRevision, s.displayKeys[0], right.slotId, right.asset.requestId), true)
  const current = session.snapshot()
  assert.equal(current.frames.find(f => f.part.sourceIndex === 0).asset.phase, 'decoding')
  assert.equal(current.frames.find(f => f.part.sourceIndex === 1).asset.phase, 'failed')
  assert.deepEqual(calls.load.filter(c => c[2]), [['A-0', 'original', true]])
  assert.equal(current.observedAnchor, null)
  session.close()
})

test('late metrics for a previous continuous row preserve the core current original point', async () => {
  const { session, key, catalog } = setup()
  const originalPage = catalog.page
  catalog.page = async (...args) => { const page = await originalPage(...args); page.width = 0; page.height = 0; return page }
  session.setPolicy(policy({ layout: 'continuous' })); session.setNeighborPreload(true)
  await session.open(key, 1); await tick()
  let s = session.snapshot()
  session.setContinuousRange(1, 1, s.topologyRevision, s.navigationRevision)
  const previous = s.window.find(w => w.index === 0).frames[0]
  decode(session, previous)
  decode(session, s.frames[0], 800, 1200)
  s = session.snapshot()
  session.reportContinuousVisible(s.topologyRevision, s.navigationRevision, '1:whole',
    s.frames[0].slotId, s.frames[0].asset.assetRequestId, 0.5, 0.35)
  decode(session, previous, 1200, 700)
  const refined = session.snapshot()
  assert.equal(refined.displayIndex, 1)
  assert.equal(refined.anchor.pageKey, 'A-1'); assert.equal(refined.anchor.y, 0.35)
  assert.equal(refined.observedAnchor.y, 0.35)
  assert.equal(refined.navigationRevision, s.navigationRevision)
  assert.equal(refined.topologyRevision, s.topologyRevision)
  assert.equal(refined.pageMetadata.find(p => p.sourceIndex === 0).height, 700)
  session.close()
})

test('paged retry keeps the selected physical half and rejects the other half action', async () => {
  const { session, key, calls } = setup({ wide: [0] })
  session.setPolicy(policy({ splitWidePages: true })); session.setNeighborPreload(true)
  await session.open(key); await tick()
  decode(session, session.snapshot().frames[0]); session.move('next')
  const before = session.snapshot(), frame = before.frames[0]
  assert.equal(frame.part.fragment, 'right')
  session.reportCachedRenderFailure(before.topologyRevision, '0:right', frame.slotId,
    frame.asset.assetRequestId, 'right')
  const failed = session.snapshot().frames[0]
  assert.equal(failed.asset.phase, 'failed')
  assert.equal(await session.retryItem(before.topologyRevision, '0:left', failed.slotId, failed.asset.requestId), false)
  assert.equal(await session.retryItem(before.topologyRevision, '0:right', failed.slotId, failed.asset.requestId), true)
  const after = session.snapshot()
  assert.equal(after.displayIndex, before.displayIndex)
  assert.equal(after.anchor.fragment, 'right'); assert.equal(after.anchor.x, 0.75)
  assert.equal(after.frames[0].slotId, frame.slotId)
  session.reportCachedRenderFailure(before.topologyRevision, '0:right', frame.slotId,
    frame.asset.assetRequestId, 'right')
  assert.equal(session.snapshot().frames[0].asset.phase, after.frames[0].asset.phase)
  assert.equal(session.snapshot().frames[0].asset.assetRequestId, after.frames[0].asset.assetRequestId)
  assert.deepEqual(calls.load.filter(call => call[2]), [['A-0', 'original', true]])
  decode(session, after.frames[0])
  assert.equal(session.reportVisible(after.selectionId, after.frames[0].slotId,
    after.frames[0].asset.assetRequestId, 'right'), true)
  session.close()
})

test('paged neighbor retry retains the healthy selected original and its observed anchor', async () => {
  const { session, key, calls } = setup()
  session.setPolicy(policy({ layout: 'spread' })); await session.open(key); await tick()
  const initial = session.snapshot()
  initial.frames.forEach(frame => decode(session, frame))
  const before = session.snapshot(), healthy = before.frames[0], other = before.frames[1]
  assert.equal(session.reportVisible(before.selectionId, healthy.slotId, healthy.asset.assetRequestId, 'whole'), true)
  session.reportCachedRenderFailure(before.topologyRevision, before.displayKeys[before.displayIndex],
    other.slotId, other.asset.assetRequestId, 'whole')
  const failed = session.snapshot().frames[1]
  assert.equal(await session.retryItem(before.topologyRevision, before.displayKeys[before.displayIndex],
    failed.slotId, failed.asset.requestId), true)
  const after = session.snapshot()
  assert.equal(after.anchor.pageKey, 'A-0'); assert.equal(after.observedAnchor.pageKey, 'A-0')
  assert.equal(after.frames[0].slotId, healthy.slotId)
  assert.equal(after.frames[0].asset.assetRequestId, healthy.asset.assetRequestId)
  assert.equal(after.frames[0].asset.phase, 'displayed')
  assert.deepEqual(calls.load.filter(call => call[2]), [['A-1', 'original', true]])
  assert.equal(calls.open.length, 1)
  session.close()
})
