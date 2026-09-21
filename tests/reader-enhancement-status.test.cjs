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

  value.state.frames = [{ part: { sourceIndex: 1 }, asset: { variant: 'enhanced' } }]
  assert.equal(value.enhancementApplied(), false)
  value.state.frames.push({ part: { sourceIndex: 0 }, asset: { variant: 'enhanced' } })
  assert.equal(value.enhancementApplied(), true)

  value.variantPolicy = { defaultPreference: () => ({ variant: 'default', identity: '' }) }
  assert.equal(value.enhancementVisible(), false)
  value.variantPolicy = { defaultPreference: () => ({ variant: 'enhanced', identity: '' }) }
  assert.equal(value.enhancementVisible(), false)
})

test('temporary status control is a child hot zone and visibly distinguishes the current-unit override', () => {
  const status = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderEnhancementStatus.ets'), 'utf8')
  const chrome = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderChrome.ets'), 'utf8')
  const pageStatus = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPageStatus.ets'), 'utf8')
  assert.match(status, /@Param enhancementEnabled: boolean = true/)
  assert.match(status, /HitTestMode\.Block/)
  assert.match(status, /\.opacity\(this\.enhancementEnabled \? 0\.78 : 0\.39\)/)
  assert.match(chrome, /this\.enhancementToggleAvailable \? HitTestMode\.Transparent : HitTestMode\.None/)
  assert.match(pageStatus, /this\.enhancementToggleAvailable \? HitTestMode\.Transparent : HitTestMode\.None/)
})
