const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function methods(names) {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  const bodies = names.map(name => {
    const match = new RegExp('^  (?:private )?' + name + '\\(', 'm').exec(source)
    assert.ok(match, name)
    const start = match.index
    const brace = source.indexOf('{', start)
    let depth = 1
    let end = brace + 1
    for (; depth; end++) {
      if (source[end] === '{') depth++
      else if (source[end] === '}') depth--
    }
    return source.slice(start, end)
  })
  const context = { exports: {} }
  vm.runInNewContext(ts.transpileModule(`export class Subject {${bodies.join('\n')}}`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, context)
  return context.exports.Subject
}

const Surface = methods([
  'enhancementSourceIndex',
  'enhancementVisible',
  'enhancementProcessing',
  'enhancementApplied',
])

const contrastContext = { exports: {} }
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderEnhancementContrast.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, contrastContext)

test('translucent enhancement fill keeps icon contrast over light and dark comics', () => {
  const { readerEnhancementContentColor: ink, READER_ENHANCEMENT_ACTIVE_ALPHA: alpha } = contrastContext.exports
  assert.equal(alpha, 0.8) // User requested some transparency while keeping the adopted theme fill.
  const linear = channel => { const v = channel / 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4 }
  for (const rgb of [[37, 110, 93], [166, 106, 31], [0, 0, 0], [117, 117, 117], [118, 118, 118], [255, 255, 255], [255, 255, 0]]) {
    const color = ink(...rgb)
    for (const page of [0, 255]) {
      const channels = rgb.map(channel => linear(channel * alpha + page * (1 - alpha)))
      const l = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
      const ratio = color === '#000000' ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05)
      assert.ok(ratio >= 3, `Icon contrast ${ratio} for ${rgb} over ${page}`)
    }
  }
})

function surface() {
  const value = new Surface()
  value.variantPolicy = { defaultPreference: () => ({ variant: 'enhanced', identity: 'model:v1' }) }
  value.state = {
    anchor: { sourceIndexHint: 0 },
    frames: [],
    isPreparingVariant(sourceIndex, variant) {
      return sourceIndex === 0 && variant === 'enhanced'
    },
  }
  return value
}

test('enhancement status follows only the current source and requested host variant', () => {
  const value = surface()
  assert.equal(value.enhancementVisible(), true)
  assert.equal(value.enhancementProcessing(), true)
  assert.equal(value.enhancementApplied(), false)

  value.state.isPreparingVariant = (sourceIndex, variant) => sourceIndex === 1 && variant === 'enhanced'
  assert.equal(value.enhancementProcessing(), false)

  value.state.frames = [{ part: { sourceIndex: 1 }, asset: { variant: 'enhanced', phase: 'displayed' } }]
  assert.equal(value.enhancementApplied(), false)
  value.state.frames.push({ part: { sourceIndex: 0 }, asset: { variant: 'enhanced', phase: 'displayed' } })
  assert.equal(value.enhancementApplied(), true)

  const current = value.state.frames[1]
  for (const phase of ['idle', 'asset', 'decoding', 'failed', 'suppressed']) {
    current.asset.phase = phase
    assert.equal(value.enhancementApplied(), false, phase + ' is not an applied image')
  }
  current.asset.phase = 'displayed'
  assert.equal(value.enhancementApplied(), true)

  value.variantPolicy = { defaultPreference: () => ({ variant: 'default', identity: '' }) }
  assert.equal(value.enhancementVisible(), false)
  value.variantPolicy = { defaultPreference: () => ({ variant: 'enhanced', identity: '' }) }
  assert.equal(value.enhancementVisible(), false)
})
