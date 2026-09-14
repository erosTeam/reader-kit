const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderImageInformation') }
const exportsUI = {}
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderLabAssetProbe.ets'), 'utf8')
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, {
  exports: exportsUI, console,
  require: name => {
    if (name === '@reader-kit/core') return core
    assert.equal(name, './ReaderFileInformation')
    // Device file-header APIs are outside these load-routing behavior tests.
    return { ReaderFileInformation: class { constructor() { throw new Error('unexpected information probe') } } }
  },
})
const { ReaderLabAssetProbe } = exportsUI
const missingOriginal = 'file:///data/storage/el2/base/cache/rkit-probe-missing-original'
const missingThumbnail = 'file:///data/storage/el2/base/cache/rkit-probe-missing-thumbnail'
function page(index) {
  return new core.ReaderPage(new core.ReaderUnitKey('nh', 'work', 'work'), `page${index}`, index)
}
function provider() {
  const calls = []
  const asset = new core.ReaderAsset('file:///real-original')
  return {
    calls, asset, cancellationMode: 'consumer-only', informationSupported: true,
    async load(...args) { calls.push(args); return asset },
  }
}

test('default original probe is disabled and delegates the original arguments and asset', async () => {
  const backend = provider()
  const probe = new ReaderLabAssetProbe(backend, -1)
  const original = page(0)
  const cancellation = new core.ReaderCancellation()
  assert.equal(await probe.load(original, 'original', cancellation, true), backend.asset)
  assert.deepEqual(backend.calls, [[original, 'original', cancellation, true]])
  assert.equal(probe.cancellationMode, backend.cancellationMode)
  assert.equal(probe.informationSupported, true)
})

test('original probe matches kind and source index, then retry and later loads delegate', async () => {
  const backend = provider()
  const probe = new ReaderLabAssetProbe(backend, -1, '', 1)
  const cancellation = new core.ReaderCancellation()
  assert.equal(await probe.load(page(0), 'original', cancellation, false), backend.asset)
  assert.equal(await probe.load(page(1), 'thumbnail', cancellation, false), backend.asset)
  assert.equal((await probe.load(page(1), 'original', cancellation, false)).uri, missingOriginal)
  assert.equal(backend.calls.length, 2)
  const retry = page(1)
  assert.equal(await probe.load(retry, 'original', cancellation, true), backend.asset)
  assert.deepEqual(backend.calls[2], [retry, 'original', cancellation, true])
  assert.equal(await probe.load(retry, 'original', cancellation, false), backend.asset)
})

test('optional acquisition failure message rejects once without owning host classification', async () => {
  const backend = provider()
  const probe = new ReaderLabAssetProbe(backend, -1, '', 1, '', 'image509')
  const cancellation = new core.ReaderCancellation()
  await assert.rejects(probe.load(page(1), 'original', cancellation, false), /image509/)
  assert.equal(await probe.load(page(1), 'original', cancellation, true), backend.asset)
})

test('thumbnail and original failures have independent one-shot state in either order', async () => {
  for (const order of [['thumbnail', 'original'], ['original', 'thumbnail']]) {
    const backend = provider()
    const probe = new ReaderLabAssetProbe(backend, 0, '', 0)
    const cancellation = new core.ReaderCancellation()
    for (const kind of order) {
      assert.equal((await probe.load(page(0), kind, cancellation, false)).uri,
        kind === 'original' ? missingOriginal : missingThumbnail)
    }
    assert.equal(backend.calls.length, 0)
    for (const kind of order) assert.equal(await probe.load(page(0), kind, cancellation, true), backend.asset)
    assert.equal(backend.calls.length, 2)
  }
})

test('a cancelled load does not consume the original failure or call the provider', async () => {
  const backend = provider()
  const probe = new ReaderLabAssetProbe(backend, -1, '', 0)
  const cancelled = new core.ReaderCancellation()
  cancelled.cancel()
  await assert.rejects(probe.load(page(0), 'original', cancelled, false))
  assert.equal(backend.calls.length, 0)
  assert.equal((await probe.load(page(0), 'original', new core.ReaderCancellation(), false)).uri, missingOriginal)
  await assert.rejects(probe.load(page(0), 'original', cancelled, true))
  assert.equal(backend.calls.length, 0)
})

test('concurrent matching loads consume only one original failure', async () => {
  const backend = provider()
  const probe = new ReaderLabAssetProbe(backend, -1, '', 0)
  const cancellation = new core.ReaderCancellation()
  const results = await Promise.all([
    probe.load(page(0), 'original', cancellation, false),
    probe.load(page(0), 'original', cancellation, false),
  ])
  assert.equal(results[0].uri, missingOriginal)
  assert.equal(results[1], backend.asset)
  assert.equal(backend.calls.length, 1)
})

test('optional original capability is forwarded only when supported and retains provider receiver', async () => {
  const backend = provider()
  assert.equal(new ReaderLabAssetProbe(backend, -1).prepareOriginal, undefined)
  const original = page(0), cancellation = new core.ReaderCancellation()
  backend.prepareOriginal = async function(p, c) {
    assert.equal(this, backend); assert.equal(p, original); assert.equal(c, cancellation)
    return { page: p, load: async () => backend.asset }
  }
  const probe = new ReaderLabAssetProbe(backend, -1)
  const plan = await probe.prepareOriginal(original, cancellation)
  assert.equal(plan.page, original)
  cancellation.cancel()
  assert.throws(() => probe.prepareOriginal(original, cancellation))
})

test('optional processed variant capability forwards exact host identity and cancellation', async () => {
  const backend = provider()
  assert.equal(new ReaderLabAssetProbe(backend, -1).prepareVariant, undefined)
  const original = page(0), cancellation = new core.ReaderCancellation()
  backend.prepareVariant = async function(p, variant, identity, c) {
    assert.equal(this, backend); assert.equal(p, original); assert.equal(variant, 'enhanced')
    assert.equal(identity, 'model-a:2000'); assert.equal(c, cancellation)
    return { page: p, variant, identity, load: async () => backend.asset }
  }
  const probe = new ReaderLabAssetProbe(backend, -1)
  const plan = await probe.prepareVariant(original, 'enhanced', 'model-a:2000', cancellation)
  assert.equal(plan.identity, 'model-a:2000')
  cancellation.cancel()
  assert.throws(() => probe.prepareVariant(original, 'enhanced', 'model-a:2000', cancellation))
})

test('information wrapping preserves original availability and delegates lease release once', async () => {
  const backend = provider(); let releases = 0
  backend.asset = new core.ReaderAsset('file:///real', () => releases++, { read: async () => ({}) })
  backend.load = async () => backend.asset
  backend.asset.originalAvailable = true
  const probe = new ReaderLabAssetProbe(backend, -1, 'fail-once')
  const asset = await probe.load(page(0), 'original', new core.ReaderCancellation(), false)
  assert.equal(asset.originalAvailable, true)
  asset.release(); asset.release(); assert.equal(releases, 1)
})

test('variant preparation failure is consumed once without invoking the backend or changing default loads', async () => {
  const backend = provider(), p = page(1), c = new core.ReaderCancellation(); let preparations = 0
  const plan = { page: p, load: async () => backend.asset }
  backend.prepareOriginal = async () => { preparations++; return plan }
  const probe = new ReaderLabAssetProbe(backend, -1, '', -1, 'prepare-fail-once')
  await assert.rejects(probe.prepareOriginal(p, c), /reader_lab_original_prepare_failure/)
  assert.equal(preparations, 0)
  assert.equal(await probe.load(p, 'original', c, false), backend.asset)
  assert.equal(await probe.prepareOriginal(p, c), plan)
  assert.equal(preparations, 1)
})

test('variant decode probe retains resolved identity and forwards retry to the same original recipe', async () => {
  const backend = provider(), p = page(1), c = new core.ReaderCancellation(), calls = []
  const plan = { page: p, async load(...args) { calls.push(args); return backend.asset } }
  backend.prepareOriginal = async () => plan
  const probe = new ReaderLabAssetProbe(backend, -1, '', -1, 'decode-fail-once')
  const wrapped = await probe.prepareOriginal(p, c)
  assert.equal(wrapped.page.key, p.key)
  assert.match((await wrapped.load(c, false)).uri, /rkit-probe-missing-original-variant$/)
  assert.equal(calls.length, 0)
  assert.equal(await wrapped.load(c, true), backend.asset)
  assert.deepEqual(calls, [[c, true]])
  assert.equal(await probe.prepareOriginal(p, c), plan)
})
