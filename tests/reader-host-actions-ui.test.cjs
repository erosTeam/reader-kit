const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const root = path.join(__dirname, '../reader-ui/src/main/ets')
const chromeSource = fs.readFileSync(path.join(root, 'ReaderChrome.ets'), 'utf8')
const surfaceSource = fs.readFileSync(path.join(root, 'ReaderSurface.ets'), 'utf8')

function methods(names) {
  const bodies = names.map(name => {
    const match = new RegExp(`^  private ${name}\\(`, 'm').exec(chromeSource)
    assert.ok(match, name)
    const start = match.index
    const brace = chromeSource.indexOf('{', start)
    let depth = 1
    let end = brace + 1
    for (; depth; end++) {
      if (chromeSource[end] === '{') depth++
      else if (chromeSource[end] === '}') depth--
    }
    return chromeSource.slice(start, end)
  })
  const output = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject {${bodies.join('\n')}}`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: output })
  return output.Subject
}

test('host settings replaces only the top duplicate while bottom runtime menu remains', () => {
  assert.match(chromeSource, /if \(this\.hostSettingsAvailable\)[\s\S]*id\('rkit-host-settings'\)[\s\S]*onClick\(this\.onHostSettings\)/)
  assert.match(chromeSource, /else \{[\s\S]*id\('rkit-runtime-settings'\)[\s\S]*bindMenu\(this\.RuntimeMenu/)
  assert.match(chromeSource, /id\('rkit-reading-mode'\)[\s\S]*bindMenu\(this\.RuntimeMenu/)
})

test('external open is an explicit stale-guarded host action', () => {
  const Chrome = methods(['selectExternalOpen'])
  const key = { value: 'u', copy() { return { value: this.value, copy: this.copy, equals: this.equals } },
    equals(other) { return other?.value === this.value } }
  const calls = []
  const chrome = new Chrome()
  Object.assign(chrome, { active: true, externalOpenAvailable: true, moreShown: true, moreUnit: key,
    snapshot: { phase: 'ready', unit: { key } }, onExternalOpen: source => calls.push(source.value) })
  chrome.selectExternalOpen()
  assert.deepEqual(calls, ['u'])
  assert.equal(chrome.moreShown, false)
  chrome.moreUnit = key
  chrome.snapshot = { phase: 'ready', unit: { key: { value: 'other', equals: key.equals } } }
  chrome.selectExternalOpen()
  assert.deepEqual(calls, ['u'])
})

test('generic host page actions carry only an exact stale-guarded reading target', () => {
  const Chrome = methods(['selectHostAction'])
  const key = { value: 'u', copy() { return { value: this.value, copy: this.copy, equals: this.equals } },
    equals(other) { return other?.value === this.value } }
  const calls = []
  const action = { id: 'translate', label: 'Translate', enabled: true, checked: false, busy: false }
  const chrome = new Chrome()
  Object.assign(chrome, { active: true, moreShown: true, moreUnit: key, moreNavigation: 7,
    snapshot: { phase: 'ready', navigationRevision: 7, anchor: { sourceIndexHint: 2 }, unit: { key } },
    onHostAction: (...values) => calls.push(values) })
  chrome.selectHostAction(action)
  assert.deepEqual(calls.map(values => [values[0], values[2], values[3]]), [['translate', 7, 2]])
  chrome.moreUnit = key; chrome.moreNavigation = 7; chrome.snapshot.navigationRevision = 8
  chrome.selectHostAction(action)
  assert.equal(calls.length, 1)
  chrome.moreUnit = key; chrome.moreNavigation = 8; action.busy = true
  chrome.selectHostAction(action)
  assert.equal(calls.length, 1)
})

test('manual reload emits one exact visible frame and rejects stale menu context', () => {
  const Chrome = methods(['currentReloadFrame', 'selectReload'])
  const key = { value: 'u', copy() { return { value: this.value, copy: this.copy, equals: this.equals } },
    equals(other) { return other?.value === this.value } }
  const frame = { slotId: 3, asset: { requestId: 9, phase: 'displayed', page: { key: 'p0' } } }
  const calls = []
  const chrome = new Chrome()
  Object.assign(chrome, { active: true, reloadAvailable: true, moreShown: true, moreUnit: key,
    moreTopology: 4, moreNavigation: 7, snapshot: { phase: 'ready', topologyRevision: 4,
      navigationRevision: 7, displayIndex: 0, displayKeys: ['0:whole'], frames: [frame], unit: { key } },
    onReload: (...values) => calls.push(values) })
  chrome.selectReload(frame)
  assert.deepEqual(calls.map(values => [values[0].slotId, values[2], values[3], values[4]]),
    [[3, 4, 7, '0:whole']])
  chrome.moreShown = true; chrome.moreUnit = key; chrome.moreTopology = 4; chrome.moreNavigation = 7
  chrome.snapshot.navigationRevision = 8
  chrome.selectReload(frame)
  assert.equal(calls.length, 1)
})

test('surface keeps per-source variant policy and completion feedback host-owned', () => {
  assert.match(surfaceSource, /variantPreferenceResolver\?\.\(frame\.part\.sourceIndex\)/)
  assert.match(surfaceSource, /this\.variantPreferenceRevision/)
  assert.match(surfaceSource, /this\.onVariantSelection\(frame\.part\.sourceIndex/)
  assert.match(surfaceSource, /hostActions: this\.hostActions/)
  assert.match(chromeSource, /ForEach\(this\.hostActions/)
  assert.match(surfaceSource, /if \(this\.hostStatusVisible && this\.hostStatusText\.length > 0\)/)
  assert.match(surfaceSource, /id\('rkit-host-status'\)/)
})

test('runtime policy intents identify the exact setting changed', () => {
  const Chrome = methods(['setLayout', 'toggleSpreadLayout'])
  const calls = []
  const chrome = new Chrome()
  Object.assign(chrome, { snapshot: { policy: { layout: 'single', pagingAxis: 'horizontal', spreadLayout: 'joined',
    copy() { return { ...this, copy: this.copy } } } }, onPolicy: (policy, intent) => calls.push([policy, intent]) })
  chrome.setLayout('continuous')
  chrome.toggleSpreadLayout()
  chrome.snapshot.policy.layout = 'spread'
  chrome.toggleSpreadLayout()
  assert.equal(calls[0][1], 'layout')
  assert.equal(calls[0][0].layout, 'continuous')
  assert.equal(calls.length, 2)
  assert.equal(calls[1][1], 'spread_layout')
  assert.equal(calls[1][0].spreadLayout, 'split')
})

test('surface publishes host-neutral crop and policy events after applying runtime state', () => {
  assert.match(surfaceSource, /this\.session\.setCropEnabled\(!this\.state\.cropEnabled\)\s+this\.onCropChanged\(this\.session\.snapshot\(\)\.cropEnabled, policy\)/)
  assert.match(surfaceSource, /this\.session\.setPolicy\(policy\)\s+this\.onPolicyChanged\(this\.session\.snapshot\(\)\.policy\.copy\(\), intent\)/)
  assert.match(chromeSource, /layout !== 'continuous' && this\.snapshot\.policy\.pagingAxis !== 'vertical'/)
})

test('single and spread image-information entries keep distinct semantic ids', () => {
  assert.equal((chromeSource.match(/\.id\('rkit-image-info'\)/g) ?? []).length, 1)
  assert.match(chromeSource, /\.id\('rkit-image-info-spread'\)/)
})

test('manual source reload keeps single and spread semantic ids distinct', () => {
  assert.equal((chromeSource.match(/\.id\('rkit-reload-source'\)/g) ?? []).length, 1)
  assert.match(chromeSource, /\.id\('rkit-reload-source-spread'\)/)
  assert.match(chromeSource, /rkit-reload-source-\$\{frame\.part\.sourceIndex\}/)
  assert.match(surfaceSource, /this\.session\.reloadItem\(topology, navigation, itemKey, frame\.slotId, frame\.asset\.requestId\)/)
})

test('manual reload alone keeps the more menu trigger enabled', () => {
  assert.match(chromeSource, /\.enabled\(this\.active && this\.snapshot\.phase === 'ready' && \(this\.reloadAvailable \|\|/)
})
