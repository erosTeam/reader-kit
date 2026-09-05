const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')
const test = require('node:test')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

// Execute the real platform-free core. No source-shape or UI assertions.
const file = path.resolve(__dirname, '../reader-core/src/main/ets/ReaderSession.ets')
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText
const coreModule = new Module(file, module)
coreModule.filename = file
coreModule._compile(compiled, file)
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = coreModule.exports

const key = (unit = 'A') => new ReaderUnitKey('test', 'work', unit)
const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
class Catalog {
  async open(key) { return new ReaderUnit(key, key.unit, 3) }
  async page(unit, index) { return new ReaderPage(unit.key, `${unit.key.unit}:${index}`, index) }
  adjacent(unit, direction) { return unit.key.unit === 'A' && direction === 'next' ? key('B') : null }
}
class Assets {
  cancellationMode = 'consumer-only'
  released = []
  async load(page) { return new ReaderAsset(page.key, () => this.released.push(page.key)) }
}

test('open owns its requested key even if the caller mutates it during preparation', async () => {
  const pending = deferred()
  const catalog = new Catalog()
  catalog.open = async requested => { await pending.promise; return new ReaderUnit(requested, 'A', 3) }
  const session = new ReaderSession(catalog, new Assets())
  const original = key()
  const opening = session.open(original)
  original.unit = 'mutated'
  pending.resolve()
  await opening
  assert.equal(session.snapshot().unit.key.unit, 'A')
  assert.equal(session.snapshot().phase, 'decoding')
  session.close()
})

test('decode failure retry asks the provider to replace a corrupt cached original', async () => {
  const assets = new Assets()
  const attempts = []
  assets.load = async (page, kind, cancellation, forceReload) => {
    attempts.push({ kind, forceReload })
    return new ReaderAsset(forceReload ? 'recovered' : 'corrupt')
  }
  const session = new ReaderSession(new Catalog(), assets)
  await session.open(key())
  session.reportPresentation(session.snapshot().requestId, false)
  assert.equal(session.snapshot().error, 'reader_decode_failed')
  await session.retry()
  assert.deepEqual(attempts, [{ kind: 'original', forceReload: false }, { kind: 'original', forceReload: true }])
  assert.equal(session.snapshot().uri, 'recovered')
  session.reportPresentation(session.snapshot().requestId, true)
  assert.equal(session.snapshot().phase, 'displayed')
  session.close()
})

test('file ready is not displayed; only current decode callback can confirm it', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  await session.open(key())
  const first = session.snapshot()
  assert.equal(first.phase, 'decoding')
  session.reportPresentation(first.requestId - 1, true)
  assert.equal(session.snapshot().phase, 'decoding')
  session.reportPresentation(first.requestId, true)
  assert.equal(session.snapshot().phase, 'displayed')
  await session.show(1)
  session.reportPresentation(first.requestId, false)
  assert.equal(session.snapshot().phase, 'decoding')
  session.close()
})

test('late asset after navigation is released and cannot replace the new page', async () => {
  const old = deferred()
  const assets = new Assets()
  const original = assets.load.bind(assets)
  assets.load = page => page.sourceIndex === 0 ? old.promise : original(page)
  const session = new ReaderSession(new Catalog(), assets)
  const opening = session.open(key())
  await new Promise(setImmediate)
  await session.show(1)
  let releases = 0
  old.resolve(new ReaderAsset('old', () => { releases++ }))
  await opening
  assert.equal(session.snapshot().uri, 'A:1')
  assert.equal(releases, 1)
  session.close()
  assert.deepEqual(assets.released, ['A:1'])
})

test('close cancels the consumer and releases a late result exactly once', async () => {
  const pending = deferred()
  let cancellation
  const assets = new Assets()
  assets.load = (_page, _kind, token) => { cancellation = token; return pending.promise }
  const session = new ReaderSession(new Catalog(), assets)
  const opening = session.open(key())
  await new Promise(setImmediate)
  session.close()
  assert.equal(cancellation.isCancelled(), true)
  let releases = 0
  pending.resolve(new ReaderAsset('late', () => { releases++ }))
  await opening
  session.close()
  assert.equal(releases, 1)
  assert.equal(session.snapshot().phase, 'closed')
})

test('failed chapter prepare retains current content; retry still targets the failed chapter', async () => {
  const catalog = new Catalog()
  let failB = true
  catalog.open = async unit => {
    if (unit.unit === 'B' && failB) throw new Error('source unavailable')
    return new ReaderUnit(unit, unit.unit, 3)
  }
  const session = new ReaderSession(catalog, new Assets())
  await session.open(key())
  await session.switchUnit('next')
  assert.equal(session.snapshot().unit.key.unit, 'A')
  assert.equal(session.snapshot().uri, 'A:0')
  assert.equal(session.snapshot().phase, 'failed')
  failB = false
  await session.retry()
  assert.equal(session.snapshot().unit.key.unit, 'B')
  session.close()
})

test('rapid chapter prepares commit only the latest unit', async () => {
  const pendingB = deferred()
  const catalog = new Catalog()
  catalog.open = unit => unit.unit === 'B' ? pendingB.promise : Promise.resolve(new ReaderUnit(unit, unit.unit, 3))
  const session = new ReaderSession(catalog, new Assets())
  const openingB = session.open(key('B'))
  await session.open(key('C'))
  pendingB.resolve(new ReaderUnit(key('B'), 'B', 3))
  await openingB
  assert.equal(session.snapshot().unit.key.unit, 'C')
  assert.equal(session.snapshot().uri, 'C:0')
  session.close()
})

test('snapshots do not expose the mutable identity or thumbnail owned by the session', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  await session.open(key())
  const snapshot = session.snapshot()
  snapshot.unit.key.unit = 'corrupt'
  snapshot.page.unit.work = 'corrupt'
  snapshot.page.thumbnail.width = 999
  assert.equal(session.snapshot().unit.key.unit, 'A')
  assert.equal(session.snapshot().page.unit.work, 'work')
  assert.equal(session.snapshot().page.thumbnail.width, 0)
  session.close()
})

test('identity mismatch is terminal and never loads an asset', async () => {
  const catalog = new Catalog()
  catalog.page = async (_unit, index) => new ReaderPage(key('wrong'), 'wrong', index)
  const assets = new Assets()
  let calls = 0
  assets.load = async () => { calls++; return new ReaderAsset('bad') }
  const session = new ReaderSession(catalog, assets)
  await session.open(key())
  assert.equal(session.snapshot().phase, 'failed')
  assert.equal(calls, 0)
  session.close()
})
