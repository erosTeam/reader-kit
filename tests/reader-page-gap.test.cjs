const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const source = fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderPageGap.ets'), 'utf8')
const context = { exports: {} }
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
} }).outputText, context)
const normalize = context.exports.normalizedReaderPageGap

test('host page gap is finite, nonnegative and bounded', () => {
  assert.equal(normalize(Number.NaN), 0)
  assert.equal(normalize(-4), 0)
  assert.equal(normalize(18), 18)
  assert.equal(normalize(200), 96)
})

test('surface forwards one host gap to both native layout owners', () => {
  const surface = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  const pager = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderPagerSurface.ets'), 'utf8')
  assert.match(surface, /@Param pageGap: number = 0/)
  assert.match(surface, /ReaderContinuousSurface\(\{[\s\S]*?pageGap: this\.pageGap/)
  assert.match(surface, /ReaderPagerSurface\(\{[\s\S]*?pageGap: this\.pageGap/)
  assert.match(pager, /ReaderPagedViewport\(\{[\s\S]*?pageGap: this\.pageGap/)
})
