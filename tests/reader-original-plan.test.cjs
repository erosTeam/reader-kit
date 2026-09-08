const test = require('node:test')
const assert = require('node:assert/strict')
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = require('./load-core.cjs')('ReaderSession')
const key = new ReaderUnitKey('test', 'work', 'unit')
const unit = new ReaderUnit(key, 'unit', 3)
const page = index => new ReaderPage(key.copy(), `page-${index}`, index)
function fixture() {
  const calls = [], released = []
  const provider = { cancellationMode: 'consumer-only', async load(p, kind, cancellation, force) {
    calls.push([p.sourceIndex, kind, force])
    const asset = new ReaderAsset(`default-${p.sourceIndex}`, () => released.push('default'))
    asset.originalAvailable = true
    return asset
  } }
  const catalog = { async open() { return unit }, async page(u, i) { return page(i) }, adjacent() { return null } }
  return { session: new ReaderSession(catalog, provider), calls, released }
}
test('resolved original plan has independent variant identity and still requires decode', async () => {
  const f = fixture(); await f.session.open(key)
  const before = f.session.snapshot(); f.session.reportPresentation(before.requestId, true)
  const loads = []
  const plan = { page: page(0), async load(cancellation, force) { loads.push(force); return new ReaderAsset('source-0') } }
  await f.session.show(0, 'original', false, plan)
  let s = f.session.snapshot()
  assert.equal(s.kind, 'original'); assert.equal(s.variant, 'original'); assert.equal(s.originalAvailable, true)
  assert.equal(s.phase, 'decoding'); assert.equal(s.sourceIndex, 0)
  assert.equal(s.uri, 'source-0'); assert.notEqual(s.assetRequestId, before.assetRequestId)
  f.session.reportPresentation(before.assetRequestId, true); assert.equal(f.session.snapshot().phase, 'decoding')
  f.session.reportPresentation(s.assetRequestId, true); assert.equal(f.session.snapshot().phase, 'displayed')
  assert.deepEqual(loads, [false]); assert.deepEqual(f.released, ['default'])
  f.session.close()
})
test('original failure retries the same variant with forceReload and does not silently downgrade', async () => {
  const f = fixture(), forces = []
  const plan = { page: page(0), async load(cancellation, force) {
    forces.push(force); if (!force) throw new Error('original unavailable'); return new ReaderAsset('source-recovered')
  } }
  await f.session.openPrepared(unit, 0, 'original', plan)
  assert.equal(f.session.snapshot().phase, 'failed'); assert.equal(f.session.snapshot().variant, 'original')
  assert.equal(f.calls.length, 0)
  await f.session.retry()
  assert.equal(f.session.snapshot().uri, 'source-recovered'); assert.equal(f.session.snapshot().variant, 'original')
  assert.deepEqual(forces, [false, true]); assert.equal(f.calls.length, 0)
  f.session.close()
})
test('default switch and thumbnail never reuse the original recipe', async () => {
  const f = fixture(); let loads = 0
  const plan = { page: page(0), async load() { loads++; return new ReaderAsset('source') } }
  await f.session.openPrepared(unit, 0, 'original', plan)
  await f.session.show(0, 'thumbnail', false, plan)
  assert.equal(f.session.snapshot().variant, 'default'); assert.equal(loads, 1)
  await f.session.show(0)
  assert.equal(f.session.snapshot().variant, 'default'); assert.equal(f.session.snapshot().uri, 'default-0')
  assert.equal(loads, 1); f.session.close()
})
test('a recipe for another source, page key or unit cannot load', async () => {
  for (const mutate of [p => p.sourceIndex++, p => p.key = 'other', p => p.unit.unit = 'other']) {
    const f = fixture(); const p = page(0); mutate(p); let loads = 0
    const plan = { page: p, async load() { loads++; return new ReaderAsset('wrong') } }
    await f.session.openPrepared(unit, 0, 'original', plan)
    assert.equal(f.session.snapshot().phase, 'failed'); assert.equal(loads, 0); assert.equal(f.calls.length, 0)
    f.session.close()
  }
})
test('late original result after navigation or close releases its own asset only', async () => {
  for (const close of [false, true]) {
    const f = fixture(); let resolve, released = 0, cancellation
    const pending = new Promise(done => { resolve = done })
    const plan = { page: page(0), async load(c) { cancellation = c; return pending } }
    const opening = f.session.openPrepared(unit, 0, 'original', plan)
    await new Promise(setImmediate)
    if (close) f.session.close(); else await f.session.show(1)
    assert.equal(cancellation.isCancelled(), true)
    resolve(new ReaderAsset('late-source', () => released++)); await opening
    assert.equal(released, 1)
    assert.equal(f.session.snapshot().phase, close ? 'closed' : 'decoding')
    assert.equal(f.session.snapshot().uri, close ? '' : 'default-1')
    f.session.close(); assert.equal(released, 1)
  }
})
