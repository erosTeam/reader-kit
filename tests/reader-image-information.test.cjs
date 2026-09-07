const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = load('ReaderSession')
const { ReaderPagedSession } = load('ReaderPagedSession')
const { ReaderDisplayPolicy } = load('ReaderDisplayMap')
const { ReaderImageInformation } = load('ReaderImageInformation')
const tick = () => new Promise(setImmediate)
const gate = () => { let resolve; const promise = new Promise(r => { resolve = r }); return { promise, resolve } }
const key = new ReaderUnitKey('source', 'work', 'chapter')
function fixture(paged = false) {
  const facts = Object.assign(new ReaderImageInformation(), { mimeType: 'image/webp', width: 1280, height: 782, bytes: 125030 })
  const calls = []
  const source = { async read(index) { calls.push(index); return facts } }
  const catalog = {
    async open(k) { return new ReaderUnit(k, 'Test', 4) },
    async page(unit, index) { const p = new ReaderPage(unit.key, `page-${index}`, index); p.width = 800; p.height = 1200; return p },
    adjacent() { return null },
  }
  const assets = { cancellationMode: 'consumer-only', informationSupported: true,
    async load(page) { return new ReaderAsset(`cached-${page.sourceIndex}.jpg`, () => {}, { read: () => source.read(page.sourceIndex) }) } }
  const session = paged ? new ReaderPagedSession(catalog, assets) : new ReaderSession(catalog, assets)
  session.setViewportActive(true)
  return { session, facts, calls, source }
}
function decoded(session) {
  for (const f of session.snapshot().frames) session.reportPresentation(f.slotId, f.asset.assetRequestId, true)
  const state = session.snapshot()
  return f => session.imageInformation(f.slotId, f.asset.assetRequestId, state.unit.key, state.navigationRevision)
}

test('information reads actual retained asset only after original presentation and copies facts', async () => {
  const { session, facts, calls } = fixture()
  await session.open(key)
  const id = session.snapshot().assetRequestId
  assert.equal(session.snapshot().informationAvailable, true)
  assert.equal(await session.imageInformation(id), null)
  assert.deepEqual(calls, [])
  session.reportPresentation(id, true)
  const result = await session.imageInformation(id)
  assert.equal(result.mimeType, 'image/webp') // cached .jpg and catalog 800x1200 are not file facts.
  assert.equal(result.width, 1280)
  result.width = 1
  assert.equal(facts.width, 1280)
  await session.show(0, 'thumbnail')
  session.reportPresentation(session.snapshot().assetRequestId, true)
  assert.equal(await session.imageInformation(session.snapshot().assetRequestId), null)
  session.close()
  assert.equal(session.snapshot().informationAvailable, false)
})

test('metadata error never changes displayed image phase and a fresh read can recover', async () => {
  const { session, source, facts } = fixture()
  await session.open(key)
  const id = session.snapshot().assetRequestId
  session.reportPresentation(id, true)
  source.read = async () => { throw Error('missing file') }
  assert.equal(await session.imageInformation(id), null)
  assert.equal(session.snapshot().phase, 'displayed')
  assert.equal(session.snapshot().error, '')
  source.read = async () => facts
  assert.equal((await session.imageInformation(id)).width, 1280)
  session.close()
})

test('late metadata is retired on replacement, retry and close', async () => {
  for (const action of ['replacement', 'retry', 'close']) {
    const { session, source, facts } = fixture()
    await session.open(key)
    const id = session.snapshot().assetRequestId
    session.reportPresentation(id, true)
    const pending = gate()
    source.read = async () => { await pending.promise; return facts }
    const read = session.imageInformation(id)
    if (action === 'replacement') await session.show(1)
    else if (action === 'retry') { session.reportRenderFailure(id); await session.retry() }
    else session.close()
    pending.resolve()
    assert.equal(await read, null, action)
    assert.equal(await session.imageInformation(id), null, action)
    session.close()
  }
})

test('spread information selects actual visual left/right source under LTR and RTL', async () => {
  for (const direction of ['ltr', 'rtl']) {
    const { session, calls } = fixture(true)
    session.setPolicy(Object.assign(new ReaderDisplayPolicy(), { layout: 'spread', direction }))
    await session.open(key); await tick()
    const read = decoded(session)
    const frames = session.snapshot().frames
    const expected = direction === 'ltr' ? [0, 1] : [1, 0]
    assert.deepEqual(frames.map(f => f.part.sourceIndex), expected)
    for (const frame of frames) assert.equal((await read(frame)).mimeType, 'image/webp')
    assert.deepEqual(calls, expected)
    session.close()
  }
})

test('paged metadata retires after navigation and background roundtrip even if old slot is cached', async () => {
  for (const action of ['navigation', 'background', 'close']) {
    const { session, source, facts } = fixture(true)
    session.setNeighborPreload(true)
    await session.open(key); await tick()
    const pending = gate()
    source.read = async () => { await pending.promise; return facts }
    const read = decoded(session)(session.snapshot().frames[0])
    if (action === 'navigation') session.move('next')
    else if (action === 'background') { session.setViewportActive(false); session.setViewportActive(true) }
    else session.close()
    pending.resolve()
    assert.equal(await read, null, action)
    session.close()
  }
})

test('information is not read for a stale unit, navigation, request or a neighboring slot', async () => {
  const { session, calls } = fixture(true)
  session.setNeighborPreload(true)
  await session.open(key); await tick(); decoded(session)
  const s = session.snapshot(), f = s.frames[0]
  const other = new ReaderUnitKey('other', 'work', 'chapter')
  assert.equal(await session.imageInformation(f.slotId, f.asset.assetRequestId, other, s.navigationRevision), null)
  assert.equal(await session.imageInformation(f.slotId, f.asset.assetRequestId, key, s.navigationRevision - 1), null)
  assert.equal(await session.imageInformation(f.slotId, f.asset.assetRequestId - 1, key, s.navigationRevision), null)
  const neighbor = s.window.flatMap(item => item.frames).find(frame => frame.slotId !== f.slotId)
  assert.ok(neighbor)
  assert.equal(await session.imageInformation(neighbor.slotId, neighbor.asset.assetRequestId, key, s.navigationRevision), null)
  assert.deepEqual(calls, [])
  session.close()
})
