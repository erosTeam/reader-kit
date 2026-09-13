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
    surface.applyPolicy(new ReaderDisplayPolicy())
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
  surface.onPolicyChanged = policy => events.push(policy)
  surface.applyPolicy(requested)
  assert.equal(events.length, 1)
  assert.notEqual(events[0], adopted)
  assert.equal(events[0].layout, 'spread')
  assert.equal(events[0].direction, 'rtl')
  assert.equal(events[0].spreadLayout, 'split')
})

test('surface reports adopted crop state without owning host persistence', () => {
  const Subject = method('toggleCrop')
  const surface = new Subject(), events = []
  surface.active = true; surface.closing = false; surface.cropAvailable = true
  surface.state = { phase: 'ready', cropEnabled: false }
  let enabled = false
  surface.session = {
    setCropEnabled(value) { enabled = value },
    snapshot() { return { cropEnabled: enabled } },
  }
  surface.onCropChanged = value => events.push(value)
  surface.toggleCrop()
  assert.deepEqual(events, [true])

  surface.cropAvailable = false
  surface.toggleCrop()
  surface.cropAvailable = true; surface.closing = true
  surface.toggleCrop()
  assert.deepEqual(events, [true])
})

test('surface chrome routes policy and crop intents through host-output gates', () => {
  assert.match(source, /@Event onPolicyChanged: \(policy: ReaderDisplayPolicy\) => void/)
  assert.match(source, /@Event onCropChanged: \(enabled: boolean\) => void/)
  assert.match(source, /onCrop: \(\): void => \{ this\.toggleCrop\(\) \}/)
  assert.match(source, /onPolicy: \(policy: ReaderDisplayPolicy\): void => \{ this\.applyPolicy\(policy\) \}/)
})
