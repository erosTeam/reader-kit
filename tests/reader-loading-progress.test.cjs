const assert = require('node:assert/strict')
const test = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset } = require('./load-core.cjs')('ReaderSession')

const key = () => new ReaderUnitKey('test', 'work', 'A')

class Catalog {
  async open(k) { return new ReaderUnit(k, k.unit, 3) }
  async page(unit, index) { return new ReaderPage(unit.key, unit.key.unit + ':' + index, index) }
  adjacent() { return null }
}

test('real asset progress reaches snapshots; total=0 never fabricates percent', async () => {
  const seen = []
  const assets = {
    cancellationMode: 'consumer-only',
    async load(page, kind, cancellation, forceReload, onProgress) {
      if (onProgress) {
        onProgress(2, 0)
        onProgress(4, 10)
        onProgress(10, 10)
      }
      return new ReaderAsset(page.key)
    },
  }
  const session = new ReaderSession(new Catalog(), assets)
  session.subscribe(snapshot => seen.push(snapshot))
  await session.open(key())
  const assetSnapshots = seen.filter(s => s.phase === 'asset')
  assert.ok(assetSnapshots.some(s => s.loadProgressLoaded === 4 && s.loadProgressTotal === 10),
    'intermediate real bytes must emit into snapshots')
  assert.ok(assetSnapshots.some(s => s.loadProgressLoaded === 10 && s.loadProgressTotal === 10),
    'completed bytes must emit into snapshots')
  assert.ok(!seen.some(s => s.loadProgressTotal === 0 && s.loadProgressLoaded === 2),
    'total=0 progress must never reach snapshots')
  assert.equal(session.snapshot().phase, 'decoding')
  session.close()
})

test('original/variant plan loads receive the same progress channel', async () => {
  const seen = []
  const assets = { cancellationMode: 'transport', async load() { throw new Error('unused') } }
  const session = new ReaderSession(new Catalog(), assets)
  session.subscribe(s => seen.push(s))
  await session.open(key())
  let received = 'none'
  const plan = {
    page: new ReaderPage(key(), 'A:1', 1),
    async load(cancellation, forceReload, onProgress) {
      received = typeof onProgress
      if (onProgress) onProgress(1, 4)
      return new ReaderAsset('file://original')
    },
  }
  await session.show(1, 'original', false, plan)
  assert.equal(received, 'function', 'plan.load must receive the progress channel')
  assert.ok(seen.some(s => s.phase === 'asset' && s.loadProgressTotal === 4),
    'plan progress must emit into snapshots')
  session.close()
})

const read = p => fs.readFileSync(path.join(__dirname, '..', p), 'utf8')

test('viewport renders the shared loading stage with phase labels and real bytes', () => {
  const viewport = read('reader-ui/src/main/ets/ReaderPagedViewport.ets')
  assert.match(viewport, /ReaderLoadingStage\(\{/)
  assert.match(viewport, /rkit_loading_resolving/)
  assert.match(viewport, /rkit_loading_image/)
  assert.match(viewport, /rkit_loading_decoding/)
  assert.match(viewport, /loadProgressLoaded/)
  assert.match(viewport, /loadProgressTotal/)
  assert.doesNotMatch(viewport, /LoadingProgress\(\)\.width\(32\)\.height\(32\)/)
  const continuous = read('reader-ui/src/main/ets/ReaderContinuousSurface.ets')
  assert.match(continuous, /ReaderLoadingStage\(\{/)
  assert.match(continuous, /rkit_loading_resolving/)
  assert.match(continuous, /rkit_loading_decoding/)
  assert.match(continuous, /loadProgressLoaded/)
  assert.doesNotMatch(continuous, /LoadingProgress\(\)\.width\(32\)\.height\(32\)/)
})

test('session threads progress into asset and plan loads; interfaces expose optional onProgress; probe forwards', () => {
  const core = read('reader-core/src/main/ets/ReaderSession.ets')
  assert.match(core, /onProgress\?: \(loaded: number, total: number\) => void/)
  assert.match(core, /assets\.load\(page\.copy\(\), kind, cancellation, forceReload, reportProgress\)/)
  assert.match(core, /plan\.load\(cancellation, forceReload, reportProgress\)/)
  assert.match(core, /value\.loadProgressTotal = this\.loadProgressTotal/)
  const probe = read('reader-ui/src/main/ets/ReaderLabAssetProbe.ets')
  assert.match(probe, /this\.provider\.load\(page, kind, cancellation, forceReload, onProgress\)/)
})

test('loading stage reuses the legacy bar geometry and all four locales carry the labels', () => {
  const stage = read('reader-ui/src/main/ets/ReaderLoadingStage.ets')
  assert.match(stage, /LOADING_BAR_WIDTH_PERCENT: string = '80%'/)
  assert.match(stage, /LOADING_BAR_MAX_WIDTH: number = 180/)
  assert.match(stage, /LOADING_SLIDER_WIDTH_RATIO: number = 0\.3/)
  assert.match(stage, /LOADING_PROGRESS_ANIM_DURATION: number = 220/)
  assert.match(stage, /LOADING_INDETERMINATE_ANIM_DURATION: number = 900/)
  for (const locale of ['base', 'zh_CN', 'en_US', 'ja_JP']) {
    const strings = JSON.parse(read('reader-ui/src/main/resources/' + locale + '/element/string.json')).string
    const names = new Set(strings.map(s => s.name))
    for (const k of ['rkit_loading_resolving', 'rkit_loading_image', 'rkit_loading_decoding']) {
      assert.ok(names.has(k), locale + ' missing ' + k)
    }
  }
})
