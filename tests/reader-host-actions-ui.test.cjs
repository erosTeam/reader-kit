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
  assert.match(surfaceSource, /this\.session\.setCropEnabled\(enabled\)\s+this\.onCropChanged\(enabled, policy\)/)
  assert.match(surfaceSource, /this\.session\.setPolicy\(policy\)\s+this\.onRuntimePolicy\(policy\.copy\(\), intent\)/)
  assert.match(chromeSource, /layout !== 'continuous' && this\.snapshot\.policy\.pagingAxis !== 'vertical'/)
})
