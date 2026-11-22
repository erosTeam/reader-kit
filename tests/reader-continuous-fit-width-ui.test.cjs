const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const uiRoot = path.resolve(__dirname, '../reader-ui/src/main/ets')
const continuous = fs.readFileSync(path.join(uiRoot, 'ReaderContinuousSurface.ets'), 'utf8')
const tree = ts.createSourceFile('ReaderContinuousSurface.ts', continuous.replace(/\bstruct /g, 'class '), ts.ScriptTarget.Latest, true)
const list = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ReaderContinuousList')
const methods = ['imageHeight'].map(name => list.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n')
const exportsObject = {}
vm.runInNewContext(ts.transpileModule(`export class List { ${methods} }`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: exportsObject })

test('continuous rows use full width, intrinsic ratio and one physical-pixel height', () => {
  const subject = new exportsObject.List()
  Object.assign(subject, { viewWidth: 400, imageAspectRatio: () => 2 / 3,
    getUIContext: () => ({ vp2px: value => value * 2.5, px2vp: value => value / 2.5 }) })
  assert.equal(subject.imageHeight(0), 600)
  subject.viewWidth = 333
  assert.equal(subject.imageHeight(0), Math.round(333 / (2 / 3) * 2.5) / 2.5)
})

test('terminal rows retain the allocated row height to avoid a jump on retry', () => {
  // The compact 220px failure fallback was superseded by the approved height-retention
  // contract (commit 34eeb49); b32b218 generalizes it: every cell state, including the
  // failed leaf, allocates the same imageHeight. The former rowHeight(220) fallback
  // no longer exists in the source.
  assert.doesNotMatch(continuous, /private rowHeight/)
  for (const branch of ['suppressed', 'failed']) {
    assert.match(continuous, new RegExp(
      `asset\\.phase === '${branch}'[\\s\\S]*?\\}\\.width\\('100%'\\)\\.height\\(this\\.imageHeight\\)`))
  }
})

test('continuous list applies the same bounded host page gap without changing image ratios', () => {
  assert.match(continuous, /space: normalizedReaderPageGap\(this\.pageGap\)/)
  assert.match(continuous, /@Param pageGap: number = 0/)
})
