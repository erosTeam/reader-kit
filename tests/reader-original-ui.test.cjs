const test = require('node:test'), assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderSession'), ...load('ReaderPagedSession'), ...load('ReaderDisplayMap') }
// Execute actual interaction methods, not builders or a simulated UI acceptance.
function methods(file, names) {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets', file + '.ets'), 'utf8')
  const bodies = names.map(name => {
    const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source)
    assert.ok(match, name)
    const start = match.index, brace = source.indexOf('{', start); let depth = 1, end = brace + 1
    for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth-- }
    return source.slice(start, end)
  })
  const context = { ...core, exports: {}, $r: (...args) => args.join(':') }
  vm.runInNewContext(ts.transpileModule(`export class Subject {${bodies.join('\n')}}`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, context)
  return context.exports.Subject
}
const Chrome = methods('ReaderChrome', ['canOriginal', 'originalTargetsCurrent', 'openOriginal', 'selectOriginal',
  'informationFrames', 'currentInformationFrame', 'selectInformation'])
const Surface = methods('ReaderSurface', ['selectOriginal'])
const tick = () => new Promise(resolve => setImmediate(resolve))
async function fixture() {
  const key = new core.ReaderUnitKey('eh', 'work', 'work')
  const provider = { cancellationMode: 'consumer-only', async load() {
    const asset = new core.ReaderAsset('default'); asset.originalAvailable = true; return asset
  }, async prepareOriginal(page) { return { page, async load() { return new core.ReaderAsset('original') } } } }
  const session = new core.ReaderPagedSession({ async open(k) { return new core.ReaderUnit(k, 'Title', 4) },
    async page(u, i) { return new core.ReaderPage(u.key, `p${i}`, i) }, adjacent() { return null } }, provider)
  const policy = new core.ReaderDisplayPolicy(); policy.layout = 'spread'; policy.direction = 'rtl'
  session.setPolicy(policy); session.setViewportActive(true); await session.open(key); await tick()
  session.snapshot().frames.forEach(f => session.reportPresentation(f.slotId, f.asset.assetRequestId, true))
  const chrome = new Chrome(), surface = new Surface(), calls = [], toasts = []
  Object.assign(chrome, { active: true, snapshot: session.snapshot(), onOriginal: (...args) => calls.push(args) })
  Object.assign(surface, { session, active: true, previewIndex: -1,
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }) })
  return { session, provider, chrome, surface, calls, toasts }
}
test('RTL original menu captures visual sides and all/mixed state controls batch intent', async () => {
  const f = await fixture(); f.chrome.openOriginal()
  assert.equal(f.chrome.originalMenuShown, true)
  assert.equal(f.chrome.originalFrames[0].part.sourceIndex, 1)
  f.chrome.selectOriginal([f.chrome.originalFrames[0]])
  assert.equal(f.calls[0][0][0].part.sourceIndex, 1); assert.equal(f.calls[0][3], true)
  f.chrome.originalFrames.forEach(frame => { frame.asset.variant = 'original' })
  f.chrome.selectOriginal(f.chrome.originalFrames); assert.equal(f.calls[1][3], false)
  f.chrome.originalFrames[1].asset.variant = 'default'
  f.chrome.selectOriginal(f.chrome.originalFrames); assert.equal(f.calls[2][3], true)
  f.session.close()
})
test('retired menu resource identity cannot toggle a new frame', async () => {
  const f = await fixture(); f.chrome.openOriginal(); const captured = f.chrome.originalFrames
  await f.session.selectOriginal(captured[0].slotId, captured[0].asset.requestId,
    f.chrome.originalUnit, f.chrome.originalNavigation, true)
  f.chrome.snapshot = f.session.snapshot(); f.chrome.selectOriginal(captured)
  assert.equal(f.calls.length, 0); f.session.close()
})

test('captured menu eligibility follows decode readiness without accepting a replacement request', async () => {
  const f = await fixture(), frame = f.chrome.snapshot.frames[0]
  frame.asset.phase = 'decoding'; frame.asset.originalAvailable = false
  f.chrome.openOriginal()
  assert.equal(f.chrome.canOriginal(frame), false)
  f.chrome.snapshot = f.session.snapshot()
  assert.equal(f.chrome.canOriginal(frame), true)
  f.chrome.snapshot.frames[0].asset.requestId++
  assert.equal(f.chrome.canOriginal(frame), false); f.session.close()
})
test('information choice follows current decode and retry facts, not its retained menu frame', async () => {
  const f = await fixture(), captured = f.chrome.snapshot.frames[0], selected = []
  captured.asset.phase = 'decoding'; captured.asset.assetRequestId = 0
  f.chrome.onInformation = frame => selected.push(frame)
  assert.equal(f.chrome.currentInformationFrame(captured.slotId), undefined)
  f.chrome.snapshot = f.session.snapshot()
  const current = f.chrome.snapshot.frames[0]
  current.asset.informationAvailable = true
  f.chrome.selectInformation(captured)
  assert.equal(selected[0], current)
  assert.notEqual(selected[0].asset.assetRequestId, captured.asset.assetRequestId)
  const retry = new core.ReaderPagedFrame(current.slotId, current.part, current.asset)
  retry.asset.assetRequestId++; retry.asset.requestId++
  f.chrome.snapshot.frames = [retry]
  f.chrome.selectInformation(captured)
  assert.equal(selected[1], retry)
  f.chrome.snapshot.frames = []
  f.chrome.selectInformation(captured)
  assert.equal(selected.length, 2)
  assert.equal(f.chrome.currentInformationFrame(captured.slotId), undefined)
  f.session.close()
})
test('batch keeps successful original and reports only failed source without moving anchor', async () => {
  const f = await fixture(), state = f.session.snapshot()
  f.provider.prepareOriginal = async page => {
    if (page.sourceIndex === 1) throw new Error('quota')
    return { page, async load() { return new core.ReaderAsset('original') } }
  }
  await f.surface.selectOriginal(state.frames, state.unit.key, state.navigationRevision, true); await tick()
  assert.equal(f.session.snapshot().frames[0].asset.variant, 'default')
  assert.equal(f.session.snapshot().frames[1].asset.variant, 'original')
  assert.equal(f.session.snapshot().anchor.sourceIndexHint, 0)
  assert.equal(f.toasts[0], 'app.string.rkit_original_failed:2'); f.session.close()
})
test('cancellation immediately clears preparing and late failure produces no current toast', async () => {
  const f = await fixture(), state = f.session.snapshot(); let reject
  f.provider.prepareOriginal = () => new Promise((_resolve, fail) => { reject = fail })
  const pending = f.surface.selectOriginal([state.frames[0]], state.unit.key, state.navigationRevision, true)
  assert.equal(f.session.snapshot().originalPreparing, true)
  f.session.cancelOriginalPreparations()
  assert.equal(f.session.snapshot().originalPreparing, false)
  reject(new Error('late')); await pending
  assert.equal(f.toasts.length, 0); f.session.close()
})

test('already-settled failure cannot toast after navigation or a changed foreground epoch', async () => {
  for (const change of ['navigation', 'epoch']) {
    const f = await fixture(), state = f.session.snapshot()
    f.surface.originalFeedbackEpoch = 1
    f.provider.prepareOriginal = async () => { throw new Error('failed') }
    let prepared = false
    f.session.subscribe(snapshot => {
      if (snapshot.originalPreparing) prepared = true
      else if (prepared) {
        prepared = false
        if (change === 'epoch') f.surface.originalFeedbackEpoch++
        else f.session.move('next')
      }
    })
    await f.surface.selectOriginal([state.frames[0]], state.unit.key, state.navigationRevision, true)
    assert.equal(f.toasts.length, 0, change); f.session.close()
  }
})
