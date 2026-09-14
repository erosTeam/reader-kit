const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const { ReaderVariantPreference } = load('ReaderSession')

function loadPolicy() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderVariantPolicy.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: () => ({ ReaderVariantPreference }) })
  return exports.ReaderVariantPolicy
}

test('variant policy copies fallback, resolved preferences and completion values', () => {
  const ReaderVariantPolicy = loadPolicy()
  const fallback = new ReaderVariantPreference('enhanced', 'model-a')
  const resolved = new ReaderVariantPreference('translated', 'translation-a')
  const completions = []
  const policy = new ReaderVariantPolicy(fallback, 7, () => resolved,
    (sourceIndex, preference, result) => completions.push({ sourceIndex, preference, result }))

  fallback.identity = 'mutated'
  const first = policy.defaultPreference()
  first.identity = 'also-mutated'
  assert.equal(policy.defaultPreference().identity, 'model-a')
  assert.equal(policy.revision, 7)
  assert.equal(policy.hasPerSourcePreference(), true)

  const preference = policy.preference(3)
  resolved.identity = 'mutated-after-resolution'
  assert.equal(preference.identity, 'translation-a')
  policy.selectionCompleted(3, preference, 'changed')
  preference.identity = 'mutated-after-completion'
  assert.deepEqual(completions.map(value => [value.sourceIndex, value.preference.identity, value.result]),
    [[3, 'translation-a', 'changed']])
})

test('variant policy defaults to the unprocessed asset without host callbacks', () => {
  const ReaderVariantPolicy = loadPolicy()
  const policy = new ReaderVariantPolicy()
  assert.equal(policy.defaultPreference().variant, 'default')
  assert.equal(policy.preference(2).variant, 'default')
  assert.equal(policy.hasPerSourcePreference(), false)
  assert.doesNotThrow(() => policy.selectionCompleted(2, new ReaderVariantPreference(), 'unchanged'))
})

test('surface exposes one optional variant policy instead of parallel host fields', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param variantPolicy: ReaderVariantPolicy \| null = null/)
  assert.match(source, /fallback\.variant, fallback\.identity, hasPerSourcePreference, this\.variantPolicy\?\.revision/)
  assert.match(source, /onVariantPolicyChanged\(\): void \{\s*this\.syncPreferredVariant/)
  assert.doesNotMatch(source, /@Param preferredVariant:/)
  assert.doesNotMatch(source, /@Param variantPreferenceResolver:/)
  assert.doesNotMatch(source, /@Event onVariantSelection:/)
})
