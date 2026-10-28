const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset, ReaderVariantPreference } = load('ReaderSession')
const { ReaderProcessingPolicy } = load('ReaderProcessingCoordinator')
const tick = () => new Promise(resolve => setImmediate(resolve))
function scenario({ deferred = false, translation = false } = {}) {
  const key = new ReaderUnitKey('source', 'work', 'A')
  const calls = { raw: [], prepared: [], release: [], promotion: [], pending: new Map() }
  const catalog = {
    async open(k) { return new ReaderUnit(k, 'book', 9) },
    async page(u, i) { const p = new ReaderPage(u.key, `${u.key.unit}-${i}`, i); p.width = 800; p.height = 1200; return p },
    adjacent() { return null },
  }
  const provider = {
    cancellationMode: 'consumer-only',
    async load(p) { calls.raw.push(p.sourceIndex); return new ReaderAsset(`raw:${p.key}`) },
    async prepareVariant(p, variant, identity, cancellation) {
      calls.prepared.push([p.sourceIndex, variant, identity, cancellation])
      cancellation.onPromotion(() => calls.promotion.push(p.sourceIndex))
      const result = { page: p.copy(), variant, identity, async load() {
        const a = new ReaderAsset(`${variant}:${p.key}:${identity}`, () => calls.release.push([p.sourceIndex, identity]))
        a.saveUri = `raw:${p.key}`
        return a
      } }
      if (!deferred) return result
      return new Promise(resolve => calls.pending.set(`${p.sourceIndex}:${identity}`, () => resolve(result)))
    },
  }
  const session = new ReaderPagedSession(catalog, provider)
  session.setViewportActive(true)
  session.setNeighborPreload(true)
  session.setPreloadDepth(4)
  const policy = identity => new ReaderProcessingPolicy(identity, translation,
    (_p, automatic) => new ReaderVariantPreference(translation && automatic ? 'translated' : 'enhanced', identity))
  session.setProcessingPolicy(policy('v1'))
  return { key, session, calls, policy }
}
function present(session, frame) { session.reportPresentation(frame.slotId, frame.asset.assetRequestId, true, 800, 1200) }

test('a future recipe is adopted on its first native slot, with no default-image intermediate or invented observation', async () => {
  const { key, session, calls } = scenario()
  await session.open(key); await tick(); await tick()
  assert.deepEqual([...new Set(calls.prepared.map(c => c[0]))].sort(), [0,1,2,3,4])
  assert.equal(session.snapshot().observedAnchor, null)
  assert.equal(session.snapshot().window.some(i => i.frames.some(f => f.part.sourceIndex === 3)), false)
  assert.equal(calls.raw.includes(3), false)
  const before = session.snapshot()
  session.seekSource(3, key, before.navigationRevision)
  await tick()
  const frame = session.snapshot().frames[0]
  assert.equal(frame.asset.variant, 'enhanced')
  assert.equal(frame.asset.uri, 'enhanced:A-3:v1')
  assert.equal(frame.asset.saveUri, 'raw:A-3')
  assert.equal(calls.raw.includes(3), false)
  assert.equal(frame.asset.phase, 'decoding')
  assert.equal(session.snapshot().isPreparingVariant(3, 'enhanced'), true)
  assert.equal(session.snapshot().observedAnchor, null)
  present(session, frame)
  assert.equal(session.snapshot().isPreparingVariant(3, 'enhanced'), false)
  session.close()
})

test('current joins the exact future task and promotes it without a second processor request', async () => {
  const { key, session, calls } = scenario({ deferred: true })
  await session.open(key); await tick()
  const prepared = calls.prepared.find(c => c[0] === 2)
  assert.equal(prepared[3].priority, 'prefetch')
  session.move('next'); session.move('next'); await tick()
  assert.equal(prepared[3].priority, 'current')
  assert.equal(calls.prepared.filter(c => c[0] === 2).length, 1)
  assert.equal(prepared[3].isCancelled(), false)
  calls.pending.get('2:v1')(); await tick(); await tick()
  assert.equal(session.snapshot().frames[0].asset.variant, 'enhanced')
  session.close()
})

test('late old configuration and unit cannot publish or keep a processor lease', async () => {
  const { key, session, calls, policy } = scenario({ deferred: true })
  await session.open(key); await tick()
  session.setProcessingPolicy(policy('v2'))
  await tick()
  calls.pending.get('0:v1')(); await tick()
  assert.notEqual(session.snapshot().frames[0].asset.variantIdentity, 'v1')
  assert.equal(calls.prepared.find(c => c[0] === 0 && c[2] === 'v1')[3].isCancelled(), true)
  calls.pending.get('0:v2')(); await tick(); await tick()
  const frame = session.snapshot().frames[0]
  assert.equal(frame.asset.variantIdentity, 'v2')
  present(session, frame)
  await session.open(new ReaderUnitKey('source', 'work', 'B')); await tick()
  assert.equal(calls.release.filter(c => c[0] === 0 && c[1] === 'v2').length, 1)
  session.close()
})

test('prepared and rendered consumers release independently; disabling keeps readable pixels until their replacement presents', async () => {
  const { key, session, calls } = scenario()
  await session.open(key); await tick(); await tick()
  const original = session.snapshot().frames[0]
  present(session, original)
  session.setProcessingPolicy(new ReaderProcessingPolicy('off', false, () => new ReaderVariantPreference()))
  await tick()
  const replacement = session.snapshot().frames[0]
  assert.equal(replacement.asset.retainedUri, original.asset.uri)
  assert.equal(replacement.asset.needsImagePlaceholder(), false)
  assert.equal(calls.release.filter(c => c[0] === 0).length, 0)
  present(session, replacement)
  assert.equal(calls.release.filter(c => c[0] === 0).length, 1)
  session.close()
})

test('automatic translation prepares exactly one future source even at zero image preload without a displayed future frame', async () => {
  for (const continuous of [false, true]) {
    const { key, session, calls } = scenario({ translation: true })
    session.setNeighborPreload(false); session.setPreloadDepth(0)
    if (continuous) { const display = session.snapshot().policy.copy(); display.layout = 'continuous'; session.setPolicy(display) }
    await session.open(key); await tick(); await tick()
    assert.deepEqual(calls.prepared.map(c => c[0]).sort(), [0,1])
    assert.equal(session.snapshot().window.length, 1)
    assert.equal(calls.raw.includes(1), false)
    assert.equal(session.snapshot().observedAnchor, null)
    session.close()
  }
})

test('crop visibility across a settings pause retains ready processed pixels; detector revision still refreshes', async () => {
  const { key, session, calls, policy } = scenario()
  session.setCropEnabled(true)
  session.setProcessingPolicy(policy('v1'), 'detector-v1')
  await session.open(key); await tick(); await tick()
  present(session, session.snapshot().frames[0])
  const before = session.snapshot().frames[0], prepared = calls.prepared.length
  session.setViewportActive(false)
  session.setCropEnabled(false)
  session.setProcessingPolicy(policy('v1'), 'detector-v1')
  session.setViewportActive(true)
  await tick(); await tick()
  const after = session.snapshot().frames[0]
  assert.equal(calls.prepared.length, prepared, 'a presentation switch must not process every cached page again')
  assert.equal(after.asset.assetRequestId, before.asset.assetRequestId)
  assert.equal(after.asset.phase, 'displayed')
  session.setCropEnabled(true)
  session.setProcessingPolicy(policy('v1'), 'detector-v2')
  await tick(); await tick()
  assert.ok(calls.prepared.length > prepared, 'a changed detector still invalidates prepared crop metadata')
  session.close()
})
