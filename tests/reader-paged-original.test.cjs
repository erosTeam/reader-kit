const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const { ReaderDisplayPolicy } = load('ReaderDisplayMap')
const tick = () => new Promise(resolve => setImmediate(resolve))
async function fixture() {
  const key = new ReaderUnitKey('source', 'work', 'unit'), calls = [], releases = []
  const catalog = {
    async open(k) { return new ReaderUnit(k.copy(), 'title', 6) },
    async page(u, i) { const p = new ReaderPage(u.key.copy(), `p${i}`, i); p.width = 800; p.height = 1200; return p },
    adjacent() { return null }
  }
  const provider = {
    cancellationMode: 'consumer-only',
    async load(p) { const a = new ReaderAsset(`default-${p.sourceIndex}`, () => releases.push(p.sourceIndex)); a.originalAvailable = true; return a },
    async prepareOriginal(p, cancellation) {
      calls.push(p.sourceIndex)
      return { page: p.copy(), async load(c, force) { return new ReaderAsset(`original-${p.sourceIndex}`) } }
    }
  }
  const s = new ReaderPagedSession(catalog, provider)
  const policy = new ReaderDisplayPolicy(); policy.layout = 'spread'; policy.direction = 'rtl'
  s.setPolicy(policy); s.setViewportActive(true); await s.open(key); await tick()
  const decode = () => s.snapshot().frames.forEach(f => s.reportPresentation(f.slotId, f.asset.assetRequestId, true))
  const frame = i => s.snapshot().frames.find(f => f.part.sourceIndex === i)
  const choose = (f, enabled = true, nav = s.snapshot().navigationRevision) => s.selectOriginal(f.slotId, f.asset.requestId, key.copy(), nav, enabled)
  decode()
  return { s, key, provider, calls, releases, decode, frame, choose }
}
test('RTL source choices are independent, preserve anchor and survive slot eviction', async () => {
  const f = await fixture(), before = f.s.snapshot(), left = f.frame(1), right = f.frame(0)
  assert.equal(await f.choose(left), 'changed'); await tick(); f.decode()
  assert.equal(f.frame(1).asset.variant, 'original'); assert.equal(f.frame(0).slotId, right.slotId)
  assert.equal(f.frame(0).asset.uri, right.asset.uri)
  assert.equal(f.s.snapshot().anchor.sourceIndexHint, before.anchor.sourceIndexHint)
  assert.equal(f.s.snapshot().navigationRevision, before.navigationRevision)
  assert.equal(await f.choose(right), 'changed'); await tick(); f.decode()
  f.s.move('next'); await tick(); f.s.move('previous'); await tick(); f.decode()
  assert.equal(f.frame(1).asset.uri, 'original-1'); assert.equal(f.frame(0).asset.uri, 'original-0')
  assert.deepEqual(f.calls, [1, 0]); f.s.close()
})
test('resolution failure or wrong recipe preserves the displayed default and selection', async () => {
  for (const wrong of [false, true]) {
    const f = await fixture(), before = f.s.snapshot(), old = f.frame(0)
    f.provider.prepareOriginal = async p => {
      if (!wrong) throw new Error('quota')
      p.key = 'different'; return { page: p, async load() { throw new Error('must not load') } }
    }
    assert.equal(await f.choose(old), 'unavailable')
    assert.equal(f.frame(0).slotId, old.slotId); assert.equal(f.frame(0).asset.uri, old.asset.uri)
    assert.equal(f.frame(0).asset.phase, 'displayed'); assert.equal(f.s.snapshot().selectionId, before.selectionId)
    assert.equal(f.releases.length, 0); f.s.close()
  }
})
test('late prepare is fenced by navigation, background, policy, thumbnail and close', async () => {
  for (const action of ['next', 'background', 'policy', 'thumbnail', 'close']) {
    const f = await fixture(); let resolve, cancel, loads = 0
    f.provider.prepareOriginal = async (p, c) => { cancel = c; return new Promise(done => {
      resolve = () => done({ page: p, async load() { loads++; return new ReaderAsset('stale') } })
    }) }
    const pending = f.choose(f.frame(0))
    if (action === 'next') f.s.move('next')
    if (action === 'background') f.s.setViewportActive(false)
    if (action === 'policy') f.s.setPolicy(new ReaderDisplayPolicy())
    if (action === 'thumbnail') {
      f.s.setAssetKind('thumbnail')
    }
    if (action === 'close') f.s.close()
    assert.equal(cancel.isCancelled(), true, action); resolve()
    assert.equal(await pending, 'stale', action); assert.equal(loads, 0); f.s.close()
  }
})
test('a newer default choice cancels pending original without releasing the current image', async () => {
  const f = await fixture(), old = f.frame(0); let resolve, cancellation
  f.provider.prepareOriginal = async (p, c) => { cancellation = c; return new Promise(done => {
    resolve = () => done({ page: p, async load() { return new ReaderAsset('late') } })
  }) }
  const pending = f.choose(old)
  assert.equal(await f.choose(old, false), 'unchanged'); assert.equal(cancellation.isCancelled(), true)
  resolve(); assert.equal(await pending, 'stale'); assert.equal(f.frame(0).slotId, old.slotId)
  assert.equal(f.releases.length, 0); f.s.close()
})
test('original load failure remains original, may retry or explicitly return to default', async () => {
  const f = await fixture(), forces = []
  f.provider.prepareOriginal = async p => ({ page: p, async load(c, force) {
    forces.push(force); throw new Error('download failed')
  } })
  assert.equal(await f.choose(f.frame(0)), 'changed'); await tick()
  assert.equal(f.frame(0).asset.phase, 'failed'); assert.equal(f.frame(0).asset.variant, 'original')
  await f.s.retry(); assert.deepEqual(forces, [false, true])
  assert.equal(await f.choose(f.frame(0), false), 'changed'); await tick(); f.decode()
  assert.equal(f.frame(0).asset.variant, 'default'); assert.equal(f.frame(0).asset.uri, 'default-0')
  f.s.close()
})
test('unsupported hosts reject original selection and reopening clears unit-scoped choices', async () => {
  const f = await fixture()
  assert.equal(await f.choose(f.frame(0)), 'changed'); await tick()
  await f.s.open(f.key); await tick(); f.decode()
  assert.equal(f.frame(0).asset.variant, 'default')
  delete f.provider.prepareOriginal
  assert.equal(f.s.originalSelectionSupported(), false)
  assert.equal(await f.choose(f.frame(0)), 'unavailable'); f.s.close()
})

test('continuous A to B to A cancels preparation even when the original slot survives', async () => {
  const f = await fixture(), policy = new ReaderDisplayPolicy()
  policy.layout = 'continuous'; f.s.setPolicy(policy); f.s.setNeighborPreload(true); await tick(); f.decode()
  const state = f.s.snapshot()
  f.s.setContinuousRange(0, 0, state.topologyRevision, state.navigationRevision)
  await tick(); f.decode()
  const old = f.frame(0); let resolve, cancellation
  f.provider.prepareOriginal = async (p, c) => { cancellation = c; return new Promise(done => {
    resolve = () => done({ page: p, async load() { throw new Error('stale plan loaded') } })
  }) }
  const pending = f.choose(old)
  f.s.setContinuousRange(1, 1, state.topologyRevision, state.navigationRevision)
  f.s.setContinuousRange(0, 0, state.topologyRevision, state.navigationRevision)
  assert.equal(f.frame(0).slotId, old.slotId)
  assert.equal(cancellation.isCancelled(), true)
  resolve(); assert.equal(await pending, 'stale')
  assert.equal(f.frame(0).asset.variant, 'default'); f.s.close()
})

test('late invalid recipe after close is stale rather than a current resolution error', async () => {
  const f = await fixture(); let resolve
  f.provider.prepareOriginal = async p => new Promise(done => {
    resolve = () => { p.key = 'wrong'; done({ page: p, async load() { throw new Error('must not load') } }) }
  })
  const pending = f.choose(f.frame(0)); f.s.close(); resolve()
  assert.equal(await pending, 'stale')
})
