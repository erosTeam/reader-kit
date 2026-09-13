const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const tick = () => new Promise(resolve => setImmediate(resolve))

async function fixture() {
  const key = new ReaderUnitKey('source', 'work', 'unit'), calls = [], releases = []
  const catalog = {
    async open(k) { return new ReaderUnit(k.copy(), 'title', 4) },
    async page(u, i) { const p = new ReaderPage(u.key.copy(), `p${i}`, i); p.width = 800; p.height = 1200; return p },
    adjacent() { return null },
  }
  const provider = {
    cancellationMode: 'consumer-only',
    async load(p) { return new ReaderAsset(`default-${p.sourceIndex}`, () => releases.push(p.sourceIndex)) },
    async prepareVariant(p, variant, identity) {
      calls.push([p.sourceIndex, variant, identity])
      return { page: p.copy(), variant, identity, async load(_c, force) {
        return new ReaderAsset(`${variant}-${p.sourceIndex}-${force ? 'retry' : 'first'}`)
      } }
    },
  }
  const s = new ReaderPagedSession(catalog, provider)
  s.setViewportActive(true); await s.open(key); await tick()
  const decode = () => s.snapshot().frames.forEach(f => s.reportPresentation(f.slotId, f.asset.assetRequestId, true))
  const frame = () => s.snapshot().frames[0]
  const choose = (variant, nav = s.snapshot().navigationRevision, identity = variant === 'default' ? '' : `${variant}:v1`) => {
    const current = frame()
    return s.selectVariant(current.slotId, current.asset.requestId, key.copy(), nav, variant, identity)
  }
  decode()
  return { s, key, provider, calls, releases, decode, frame, choose }
}

test('resolved host variant preserves page identity and changes only after preparation', async () => {
  const f = await fixture(), before = f.s.snapshot(); let resolve, cancellation
  f.provider.prepareVariant = async (page, variant, identity, c) => {
    cancellation = c
    return new Promise(done => { resolve = () => done({ page: page.copy(), variant, identity,
      async load() { return new ReaderAsset('enhanced-ready') } }) })
  }
  const pending = f.choose('enhanced')
  assert.equal(f.s.snapshot().variantPreparing, true)
  assert.equal(f.frame().asset.variant, 'default')
  assert.equal(cancellation.isCancelled(), false)
  resolve(); assert.equal(await pending, 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.uri, 'enhanced-ready')
  assert.equal(f.frame().asset.variant, 'enhanced')
  assert.equal(f.frame().asset.originalAvailable, false)
  assert.equal(f.s.snapshot().variantPreparing, false)
  assert.equal(f.s.snapshot().anchor.sourceIndexHint, before.anchor.sourceIndexHint)
  assert.equal(f.s.snapshot().navigationRevision, before.navigationRevision)
  f.s.close()
})

test('host can warm a loaded neighbor variant without moving or replacing the current source', async () => {
  const f = await fixture()
  f.s.setNeighborPreload(true); await tick()
  f.s.snapshot().window.flatMap(item => item.frames).forEach(frame =>
    f.s.reportPresentation(frame.slotId, frame.asset.assetRequestId, true))
  const before = f.s.snapshot(), navigation = before.navigationRevision
  assert.equal(await f.s.prepareVariantForSource(1, f.key.copy(), navigation, 'translated', 'translated:v1'), 'changed')
  await tick()
  f.s.snapshot().window.flatMap(item => item.frames).forEach(frame =>
    f.s.reportPresentation(frame.slotId, frame.asset.assetRequestId, true))
  assert.equal(f.frame().part.sourceIndex, 0)
  assert.equal(f.frame().asset.uri, 'default-0')
  assert.equal(f.s.snapshot().anchor.sourceIndexHint, before.anchor.sourceIndexHint)
  assert.equal(f.s.snapshot().navigationRevision, navigation)
  const warm = f.s.snapshot().window.flatMap(item => item.frames)
    .find(frame => frame.part.sourceIndex === 1)
  assert.equal(warm.asset.uri, 'translated-1-first')
  assert.equal(warm.asset.variant, 'translated')
  f.s.move('next'); await tick(); f.decode()
  assert.equal(f.frame().part.sourceIndex, 1)
  assert.equal(f.frame().asset.uri, 'translated-1-first')
  assert.deepEqual(f.calls, [[1, 'translated', 'translated:v1']])
  f.s.close()
})

test('navigation cancels a late neighbor variant preparation before it becomes a warm plan', async () => {
  const f = await fixture(); let resolve, cancellation
  f.s.setNeighborPreload(true); await tick()
  f.s.snapshot().window.flatMap(item => item.frames).forEach(frame =>
    f.s.reportPresentation(frame.slotId, frame.asset.assetRequestId, true))
  f.provider.prepareVariant = async (page, variant, identity, value) => {
    cancellation = value
    return new Promise(done => { resolve = () => done({ page, variant, identity,
      async load() { return new ReaderAsset('late-neighbor') } }) })
  }
  const pending = f.s.prepareVariantForSource(1, f.key.copy(), f.s.snapshot().navigationRevision,
    'translated', 'translated:v1')
  f.s.move('next')
  assert.equal(cancellation.isCancelled(), true)
  resolve(); assert.equal(await pending, 'stale'); await tick(); f.decode()
  assert.equal(f.frame().part.sourceIndex, 1)
  assert.equal(f.frame().asset.uri, 'default-1')
  f.s.close()
})

test('wrong derivative identity or variant leaves the displayed body untouched', async () => {
  for (const wrong of ['page', 'variant']) {
    const f = await fixture(), current = f.frame()
    f.provider.prepareVariant = async (page, variant, identity) => {
      if (wrong === 'page') page.key = 'wrong'
      return { page, variant: wrong === 'variant' ? 'translated' : variant, identity,
        async load() { throw new Error('must not load') } }
    }
    assert.equal(await f.choose('enhanced'), 'unavailable')
    assert.equal(f.frame().slotId, current.slotId)
    assert.equal(f.frame().asset.uri, current.asset.uri)
    assert.equal(f.frame().asset.phase, 'displayed')
    f.s.close()
  }
})

test('navigation, background and close fence late host processing before its recipe loads', async () => {
  for (const action of ['next', 'background', 'close']) {
    const f = await fixture(); let resolve, cancellation, loads = 0
    f.provider.prepareVariant = async (page, variant, identity, c) => {
      cancellation = c
      return new Promise(done => { resolve = () => done({ page, variant, identity,
        async load() { loads++; return new ReaderAsset('stale') } }) })
    }
    const pending = f.choose('translated')
    if (action === 'next') f.s.move('next')
    if (action === 'background') f.s.setViewportActive(false)
    if (action === 'close') f.s.close()
    assert.equal(cancellation.isCancelled(), true, action)
    resolve(); assert.equal(await pending, 'stale', action); assert.equal(loads, 0, action)
    f.s.close()
  }
})

test('one source can replace enhanced with translated then reveal its default again', async () => {
  const f = await fixture()
  assert.equal(await f.choose('enhanced'), 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.variant, 'enhanced')
  assert.equal(await f.choose('translated'), 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.variant, 'translated')
  assert.equal(f.frame().asset.uri, 'translated-0-first')
  assert.equal(await f.choose('default'), 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.variant, 'default')
  assert.equal(f.frame().asset.uri, 'default-0')
  assert.deepEqual(f.calls, [[0, 'enhanced', 'enhanced:v1'], [0, 'translated', 'translated:v1']])
  f.s.close()
})

test('processed load failure stays explicit, retries the same recipe, and may return to default', async () => {
  const f = await fixture(), forces = []
  f.provider.prepareVariant = async (page, variant, identity) => ({ page, variant, identity, async load(_c, force) {
    forces.push(force)
    if (!force) throw new Error('processing artifact unavailable')
    return new ReaderAsset('translated-recovered')
  } })
  assert.equal(await f.choose('translated'), 'changed'); await tick()
  assert.equal(f.frame().asset.phase, 'failed'); assert.equal(f.frame().asset.variant, 'translated')
  await f.s.retry(); f.decode()
  assert.deepEqual(forces, [false, true])
  assert.equal(f.frame().asset.uri, 'translated-recovered')
  assert.equal(await f.choose('default'), 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.uri, 'default-0'); f.s.close()
})

test('a changed processing identity replaces the same variant while stale identities are rejected', async () => {
  const f = await fixture()
  assert.equal(await f.choose('enhanced'), 'changed'); await tick(); f.decode()
  assert.equal(f.frame().asset.variantIdentity, 'enhanced:v1')
  assert.equal(await f.choose('enhanced'), 'unchanged')
  assert.equal(await f.choose('enhanced', f.s.snapshot().navigationRevision, 'enhanced:v2'), 'changed')
  await tick(); f.decode()
  assert.equal(f.frame().asset.variantIdentity, 'enhanced:v2')
  f.provider.prepareVariant = async (page, variant) => ({ page, variant, identity: 'wrong',
    async load() { throw new Error('must not load') } })
  assert.equal(await f.choose('enhanced', f.s.snapshot().navigationRevision, 'enhanced:v3'), 'unavailable')
  assert.equal(f.frame().asset.variantIdentity, 'enhanced:v2')
  f.s.close()
})

test('unsupported hosts reject processed variants and opening a unit clears selections', async () => {
  const f = await fixture()
  assert.equal(f.s.variantSelectionSupported(), true)
  assert.equal(await f.choose('enhanced'), 'changed'); await tick(); f.decode()
  await f.s.open(f.key); await tick(); f.decode()
  assert.equal(f.frame().asset.variant, 'default')
  delete f.provider.prepareVariant
  assert.equal(f.s.variantSelectionSupported(), false)
  assert.equal(await f.choose('enhanced'), 'unavailable')
  f.s.close()
})
