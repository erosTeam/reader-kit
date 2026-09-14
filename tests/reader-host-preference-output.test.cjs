const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const { ReaderDisplayPolicy } = load('ReaderDisplayMap')

const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')

function method(name) {
  const tree = ts.createSourceFile('ReaderSurface.ets',
    source.replace('export struct ReaderSurface', 'export class ReaderSurface'), ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderSurface')
  const member = cls.members.find(value => value.name?.getText(tree) === name)
  assert.ok(member, name)
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${member.getText(tree)} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out })
  return out.Subject
}

test('surface publishes only the display policy actually adopted by the live session', () => {
  const Subject = method('applyPolicy')
  for (const gate of [['active', false], ['closing', true], ['phase', 'opening']]) {
    const surface = new Subject()
    surface.active = true; surface.closing = false; surface.state = { phase: 'ready' }
    if (gate[0] === 'phase') surface.state.phase = gate[1]
    else surface[gate[0]] = gate[1]
    let calls = 0
    surface.session = { setPolicy() { calls++ } }
    surface.applyPolicy(new ReaderDisplayPolicy(), 'layout')
    assert.equal(calls, 0, gate[0])
  }

  const surface = new Subject(), events = [], requested = new ReaderDisplayPolicy()
  requested.layout = 'spread'; requested.direction = 'rtl'
  const adopted = requested.copy(); adopted.spreadLayout = 'split'
  surface.active = true; surface.closing = false; surface.state = { phase: 'ready' }
  surface.session = {
    setPolicy(policy) { assert.equal(policy, requested) },
    snapshot() { return { policy: adopted } },
  }
  surface.preferenceSink = { policyChanged: (policy, intent) => events.push([policy.copy(), intent]) }
  surface.applyPolicy(requested, 'spread_layout')
  assert.equal(events.length, 1)
  assert.notEqual(events[0][0], adopted)
  assert.equal(events[0][0].layout, 'spread')
  assert.equal(events[0][0].direction, 'rtl')
  assert.equal(events[0][0].spreadLayout, 'split')
  assert.equal(events[0][1], 'spread_layout')
})

test('surface reports adopted crop state without owning host persistence', () => {
  const Subject = method('toggleCrop')
  const surface = new Subject(), events = []
  surface.active = true; surface.closing = false; surface.cropAvailable = true
  const policy = new ReaderDisplayPolicy()
  policy.layout = 'continuous'
  surface.state = { phase: 'ready', cropEnabled: false, policy }
  let enabled = false
  surface.session = {
    setCropEnabled(value) { enabled = value },
    snapshot() { return { cropEnabled: enabled } },
  }
  surface.preferenceSink = { cropChanged: (value, adoptedPolicy) => events.push([value, adoptedPolicy.copy()]) }
  surface.toggleCrop()
  assert.equal(events.length, 1)
  assert.equal(events[0][0], true)
  assert.notEqual(events[0][1], policy)
  assert.equal(events[0][1].layout, 'continuous')

  surface.cropAvailable = false
  surface.toggleCrop()
  surface.cropAvailable = true; surface.closing = true
  surface.toggleCrop()
  assert.equal(events.length, 1)
})

test('surface chrome routes policy and crop intents through host-output gates', () => {
  assert.match(source, /@Param preferenceSink: ReaderPreferenceSink \| null = null/)
  assert.match(source, /onCrop: \(\): void => \{ this\.toggleCrop\(\) \}/)
  assert.match(source, /onPolicy: \(policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent\): void => \{\s+this\.applyPolicy\(policy, intent\)/)
})
