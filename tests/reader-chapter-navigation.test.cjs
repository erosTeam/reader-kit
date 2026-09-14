const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadChapterNavigation() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderChapterNavigation.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: name => {
    assert.equal(name, '@reader-kit/core')
    return {}
  } })
  return exports.ReaderChapterNavigation
}

test('chapter navigation forwards a copied current unit while keeping busy state explicit', () => {
  const ReaderChapterNavigation = loadChapterNavigation()
  const events = []
  const source = { unit: 'chapter-a', copy: () => ({ unit: 'chapter-a-copy' }) }
  const navigation = new ReaderChapterNavigation(true,
    (direction, current) => events.push([direction, current.unit]))
  assert.equal(navigation.busy, true)
  navigation.request('next', source)
  assert.deepEqual(events, [['next', 'chapter-a-copy']])
})

test('surface exposes chapter continuation as one optional capability', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param chapterNavigation: ReaderChapterNavigation \| null = null/)
  assert.doesNotMatch(source, /@Param chapterNavigationAvailable:/)
  assert.doesNotMatch(source, /@Param chapterNavigationBusy:/)
  assert.doesNotMatch(source, /@Event onChapter:/)
})
