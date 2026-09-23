const assert = require('node:assert/strict')
const test = require('node:test')
const { ReaderSession, ReaderUnitKey, ReaderUnit, ReaderPage, ReaderAsset, ReaderAssetNotice,
  ReaderAssetFailure, ReaderCancellation } = require('./load-core.cjs')('ReaderSession')

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

test('cancellation hooks release host work once and may be detached', () => {
  const cancellation = new ReaderCancellation()
  const calls = []
  cancellation.onCancel(() => calls.push('kept'))
  const detach = cancellation.onCancel(() => calls.push('detached'))
  cancellation.onCancel(() => { calls.push('throwing'); throw new Error('host cleanup failed') })
  cancellation.onCancel(() => calls.push('after-throw'))
  detach()
  cancellation.cancel()
  cancellation.cancel()
  assert.deepEqual(calls, ['kept', 'throwing', 'after-throw'])
  cancellation.onCancel(() => calls.push('late'))
  assert.deepEqual(calls, ['kept', 'throwing', 'after-throw', 'late'])
})

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

test('host asset failure classification survives snapshot copies and clears on retry', async () => {
  const assets = new Assets()
  let fail = true
  const failures = {
    classify: error => new ReaderAssetFailure('quota', 'Image quota exhausted', `Host hint: ${error.message}`),
  }
  assets.load = async page => {
    if (fail) throw new Error('509')
    return new ReaderAsset(page.key)
  }
  const session = new ReaderSession(new Catalog(), assets, failures)
  await session.open(key())
  const failed = session.snapshot()
  assert.equal(failed.phase, 'failed')
  assert.equal(failed.error, 'quota')
  assert.equal(failed.failure.title, 'Image quota exhausted')
  assert.equal(failed.failure.hint, 'Host hint: 509')
  failed.failure.title = 'mutated'
  assert.equal(session.snapshot().failure.title, 'Image quota exhausted')
  fail = false
  await session.retry()
  assert.equal(session.snapshot().failure, null)
  assert.equal(session.snapshot().error, '')
  session.close()
})

test('displayed force reload retires each fallback after the candidate reaches a composed frame', async () => {
  const firstReplacement = deferred()
  const secondReplacement = deferred()
  const releases = []
  const presentations = []
  let attempt = 0
  const assets = new Assets()
  assets.load = async (_page, _kind, _cancellation, forceReload) => {
    attempt++
    if (forceReload) return attempt === 2 ? firstReplacement.promise : secondReplacement.promise
    return new ReaderAsset('old', () => releases.push('old'), null, () => presentations.push('old'))
  }
  const session = new ReaderSession(new Catalog(), assets)
  await session.open(key())
  const old = session.snapshot()
  session.reportPresentation(old.assetRequestId, true)
  session.reportPresentation(old.assetRequestId, true)
  assert.deepEqual(presentations, ['old'])
  const reload = session.show(0, 'original', true)
  await new Promise(setImmediate)
  assert.equal(session.snapshot().phase, 'displayed')
  assert.equal(session.snapshot().uri, 'old')
  assert.equal(session.snapshot().assetRequestId, old.assetRequestId)
  assert.equal(session.snapshot().retainedUri, '')
  assert.equal(session.snapshot().retainedAssetRequestId, 0)
  assert.deepEqual(releases, [])
  firstReplacement.resolve(new ReaderAsset('new-1', () => releases.push('new-1'), null,
    () => presentations.push('new-1')))
  await reload
  const pending = session.snapshot()
  assert.equal(pending.phase, 'decoding')
  assert.equal(pending.uri, 'new-1')
  assert.equal(pending.retainedUri, 'old')
  assert.equal(pending.retainedAssetRequestId, old.assetRequestId)
  assert.notEqual(pending.assetRequestId, old.assetRequestId)
  assert.deepEqual(releases, [])
  session.reportPresentation(pending.assetRequestId, true)
  assert.deepEqual(presentations, ['old', 'new-1'])
  assert.equal(session.snapshot().retainedUri, '')
  assert.equal(session.snapshot().retainedAssetRequestId, 0)
  assert.deepEqual(releases, ['old'])

  const secondReload = session.show(0, 'original', true)
  await new Promise(setImmediate)
  assert.equal(session.snapshot().uri, 'new-1')
  assert.equal(session.snapshot().retainedUri, '')
  secondReplacement.resolve(new ReaderAsset('new-2', () => releases.push('new-2'), null,
    () => presentations.push('new-2')))
  await secondReload
  const secondPending = session.snapshot()
  assert.equal(secondPending.phase, 'decoding')
  assert.equal(secondPending.uri, 'new-2')
  assert.equal(secondPending.retainedUri, 'new-1')
  assert.equal(secondPending.retainedAssetRequestId, pending.assetRequestId)
  assert.deepEqual(releases, ['old'])
  session.reportPresentation(secondPending.assetRequestId, true)
  assert.deepEqual(presentations, ['old', 'new-1', 'new-2'])
  assert.equal(session.snapshot().retainedUri, '')
  assert.equal(session.snapshot().retainedAssetRequestId, 0)
  assert.deepEqual(releases, ['old', 'new-1'])
  session.close()
  assert.deepEqual(releases, ['old', 'new-1', 'new-2'])
  assert.equal(attempt, 3)
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

test('retained candidate needs its own foreground claim before old lease retires', async () => {
  const releases = [], presentations = [], issued = []
  let n = 0
  const assets = new Assets()
  assets.load = async () => {
    n++
    const name = n === 1 ? 'old' : 'new'
    const asset = new ReaderAsset(name, receiptId => {
      assert.equal(receiptId, asset.receiptId)
      releases.push(name)
    }, null, () => presentations.push(name))
    issued.push(asset)
    return asset
  }
  const session = new ReaderSession(new Catalog(), assets)
  await session.open(key())
  session.reportPresentation(session.snapshot().assetRequestId, true)
  const boundReceipts = [], originalBoundInfo = console.info
  console.info = message => boundReceipts.push(message)
  try {
    await session.show(0, 'original', true)
  } finally {
    console.info = originalBoundInfo
  }
  const pending = session.snapshot()
  assert.ok(boundReceipts.some(line => line.includes(`asset_bound request=${pending.assetRequestId} `) &&
    line.includes(`asset_receipt=${issued[1].receiptId}`)))
  session.reportPresentation(pending.assetRequestId, true, true)
  const claiming = session.snapshot()
  assert.equal(claiming.phase, 'claiming')
  assert.equal(claiming.retainedUri, 'old')
  assert.deepEqual(releases, [])
  assert.deepEqual(presentations, ['old'])
  session.reportVisualClaim(pending.assetRequestId, claiming.visualRevision - 1)
  session.reportVisualClaim(pending.assetRequestId - 1, claiming.visualRevision)
  assert.equal(session.snapshot().phase, 'claiming')
  const receipts = [], originalInfo = console.info
  console.info = message => receipts.push(message)
  try {
    session.reportVisualClaim(pending.assetRequestId, claiming.visualRevision)
  } finally {
    console.info = originalInfo
  }
  assert.ok(receipts.some(line => line.includes(`release_returned asset_receipt=${issued[0].receiptId}`)))
  assert.ok(receipts.some(line => line.includes(`visual_claim_retired old_request=${claiming.retainedAssetRequestId}`) &&
    line.includes(`new_request=${pending.assetRequestId} visual_revision=${claiming.visualRevision}`) &&
    line.includes(`old_asset_receipt=${issued[0].receiptId} new_asset_receipt=${issued[1].receiptId}`)))
  assert.equal(session.snapshot().phase, 'displayed')
  assert.equal(session.snapshot().retainedUri, '')
  assert.deepEqual(releases, ['old'])
  assert.deepEqual(presentations, ['old', 'new'])
  session.close()
  assert.deepEqual(releases, ['old', 'new'])
})

test('failed and superseded visual claims roll back to the displayed lease', async () => {
  const releases = []
  let n = 0
  const assets = new Assets()
  assets.load = async () => {
    n++
    const name = `asset-${n}`
    return new ReaderAsset(name, () => releases.push(name))
  }
  const session = new ReaderSession(new Catalog(), assets)
  session.setViewportActive(true)
  await session.open(key())
  session.reportPresentation(session.snapshot().assetRequestId, true)
  await session.show(0, 'original', true)
  let candidate = session.snapshot()
  session.reportPresentation(candidate.assetRequestId, true, true)
  const failedClaim = session.snapshot()
  session.reportRenderFailure(candidate.assetRequestId)
  assert.equal(session.snapshot().phase, 'displayed')
  assert.equal(session.snapshot().uri, 'asset-1')
  assert.deepEqual(releases, ['asset-2'])
  session.reportVisiblePosition(failedClaim.retainedAssetRequestId, 'A:0', 0.5, 0.4)
  assert.equal(session.snapshot().presentedAnchor.y, 0.4)
  session.reportVisualClaim(candidate.assetRequestId, failedClaim.visualRevision)
  assert.equal(session.snapshot().uri, 'asset-1')
  await session.show(0, 'original', true)
  candidate = session.snapshot()
  session.reportPresentation(candidate.assetRequestId, true, true)
  const superseded = session.snapshot()
  await session.show(0, 'original', true)
  assert.equal(session.snapshot().uri, 'asset-4')
  assert.equal(session.snapshot().retainedUri, 'asset-1')
  session.reportVisualClaim(candidate.assetRequestId, superseded.visualRevision)
  assert.equal(session.snapshot().uri, 'asset-4')
  assert.deepEqual(releases, ['asset-2', 'asset-3'])
  session.close()
  assert.deepEqual(releases, ['asset-2', 'asset-3', 'asset-1', 'asset-4'])
})

test('suppressed replacement retains old lease and its provider action can reload', async () => {
  const released = []
  let n = 0
  const assets = new Assets()
  assets.load = async () => {
    n++
    if (n === 2) {
      const notice = new ReaderAsset('', () => released.push('notice'))
      notice.setNotice(new ReaderAssetNotice('blocked', 'Blocked', 'Resolve first', 'Resolve'), async () => true)
      return notice
    }
    const name = n === 1 ? 'old' : 'recovered'
    return new ReaderAsset(name, () => released.push(name))
  }
  const session = new ReaderSession(new Catalog(), assets)
  await session.open(key())
  session.reportPresentation(session.snapshot().assetRequestId, true)
  await session.show(0, 'original', true)
  const suppressed = session.snapshot()
  assert.equal(suppressed.phase, 'suppressed')
  assert.equal(suppressed.retainedUri, 'old')
  assert.equal(suppressed.notice.id, 'blocked')
  assert.deepEqual(released, [])
  assert.equal(await session.resolveNotice(suppressed.assetRequestId, 'blocked'), true)
  const pending = session.snapshot()
  assert.equal(pending.phase, 'decoding')
  assert.equal(pending.retainedUri, 'old')
  assert.deepEqual(released, ['notice'])
  session.reportPresentation(pending.assetRequestId, true, true)
  session.reportVisualClaim(pending.assetRequestId, session.snapshot().visualRevision)
  assert.deepEqual(released, ['notice', 'old'])
  session.close()
  assert.deepEqual(released, ['notice', 'old', 'recovered'])
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

test('request/decode success alone does not publish a visible original position', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  session.setViewportActive(true)
  await session.open(key())
  const request = session.snapshot().requestId
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  assert.equal(session.snapshot().presentedAnchor, null)
  session.reportPresentation(request, true)
  assert.equal(session.snapshot().presentedAnchor, null)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  assert.equal(session.snapshot().presentedAnchor.pageKey, 'A:0')
  assert.equal(session.snapshot().presentedRequestId, request)
  session.close()
})

test('navigation, failure and thumbnails retain the last observed original', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  session.setViewportActive(true)
  await session.open(key())
  const first = session.snapshot().requestId
  session.reportPresentation(first, true)
  session.reportVisiblePosition(first, 'A:0', 0.5, 0.3)
  await session.show(2)
  let current = session.snapshot().requestId
  session.reportPresentation(current, false)
  session.reportVisiblePosition(current, 'A:2', 0.5, 1)
  assert.equal(session.snapshot().presentedAnchor.pageKey, 'A:0')
  await session.show(2, 'thumbnail')
  current = session.snapshot().requestId
  session.reportPresentation(current, true)
  session.reportVisiblePosition(current, 'A:2', 0.5, 1)
  assert.equal(session.snapshot().presentedAnchor.pageKey, 'A:0')
  assert.equal(session.snapshot().presentedAnchor.y, 0.3)
  await session.show(2)
  current = session.snapshot().requestId
  session.reportPresentation(current, true)
  session.reportVisiblePosition(first, 'A:0', 0.5, 0)
  assert.equal(session.snapshot().presentedRequestId, first)
  session.reportVisiblePosition(current, 'A:2', 0.5, 0)
  assert.equal(session.snapshot().presentedAnchor.pageKey, 'A:2')
  session.close()
})

test('only a current matching page and finite original coordinates can be observed', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  session.setViewportActive(true)
  await session.open(key())
  const request = session.snapshot().requestId
  session.reportPresentation(request, true)
  session.reportVisiblePosition(request, 'wrong', 0.5, 0)
  for (const value of [NaN, Infinity, -0.1, 1.1]) {
    session.reportVisiblePosition(request, 'A:0', value, 0)
    session.reportVisiblePosition(request, 'A:0', 0.5, value)
  }
  assert.equal(session.snapshot().presentedAnchor, null)
  session.reportVisiblePosition(request, 'A:0', 0.4, 0.6)
  const snapshot = session.snapshot()
  snapshot.presentedAnchor.unit.unit = 'mutated'
  snapshot.presentedAnchor.y = 1
  assert.equal(session.snapshot().presentedAnchor.unit.unit, 'A')
  assert.equal(session.snapshot().presentedAnchor.y, 0.6)
  session.close()
  session.reportVisiblePosition(request, 'A:0', 0.5, 1)
  assert.equal(session.snapshot().presentedAnchor.y, 0.6)
})

test('chapter transition exposes the previous observed unit until the new original is seen', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  session.setViewportActive(true)
  await session.open(key())
  let request = session.snapshot().requestId
  session.reportPresentation(request, true)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  await session.switchUnit('next')
  assert.equal(session.snapshot().unit.key.unit, 'B')
  assert.equal(session.snapshot().presentedAnchor.unit.unit, 'A')
  request = session.snapshot().requestId
  session.reportPresentation(request, true)
  session.reportVisiblePosition(request, 'B:0', 0.5, 0)
  assert.equal(session.snapshot().presentedAnchor.unit.unit, 'B')
  session.close()
})

test('retained old image cannot inherit a preparing chapter request identity', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  const frames = []
  session.subscribe(frame => frames.push(frame))
  await session.open(key())
  const old = session.snapshot()
  session.reportPresentation(old.assetRequestId, true)
  await session.switchUnit('next')
  const retained = frames.find(frame => frame.phase === 'catalog' && frame.uri === 'A:0')
  assert.notEqual(retained.requestId, old.requestId)
  assert.equal(retained.assetRequestId, old.assetRequestId)
  assert.equal(retained.page.key, 'A:0')
  assert.equal(session.snapshot().phase, 'decoding')
  session.reportPresentation(retained.assetRequestId, true)
  assert.equal(session.snapshot().phase, 'decoding')
  const current = session.snapshot()
  assert.equal(current.assetRequestId, current.requestId)
  assert.equal(current.page.key, 'B:0')
  session.reportPresentation(current.assetRequestId, true)
  assert.equal(session.snapshot().phase, 'displayed')
  session.close()
})

test('inactive viewport cannot observe and repeated identical observations do not emit again', async () => {
  const session = new ReaderSession(new Catalog(), new Assets())
  await session.open(key())
  const request = session.snapshot().assetRequestId
  session.reportPresentation(request, true)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  assert.equal(session.snapshot().presentedAnchor, null)
  session.setViewportActive(true)
  let changes = 0
  session.subscribe(() => changes++)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  assert.equal(changes, 2)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0)
  assert.equal(changes, 2)
  session.setViewportActive(false)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0.8)
  assert.equal(session.snapshot().presentedAnchor.y, 0)
  session.setViewportActive(true)
  session.reportVisiblePosition(request, 'A:0', 0.5, 0.8)
  assert.equal(session.snapshot().presentedAnchor.y, 0.8)
  session.close()
})
