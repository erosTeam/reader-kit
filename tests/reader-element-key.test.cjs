const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const root = path.join(__dirname, '../reader-ui/src/main/ets')
const source = fs.readFileSync(path.join(root, 'ReaderElementKey.ets'), 'utf8')
const exportsValue = {}
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
} }).outputText, { exports: exportsValue })
const { readerElementKey } = exportsValue

test('render element keys encode arbitrary reader and host identities into ArkUI-safe unique text', () => {
  const identities = ['', '0:whole', '0_whole', 'slot:12:left',
    'local-library-folder-chapter-3911f3a3', '章节/一']
  const keys = identities.map(readerElementKey)
  keys.forEach(key => assert.match(key, /^[A-Za-z0-9_]+$/))
  assert.equal(new Set(keys).size, identities.length)
})

test('reader surfaces keep semantic display keys but encode native collection identities', () => {
  for (const file of ['ReaderPagerSurface.ets', 'ReaderContinuousSurface.ets',
    'ReaderPagedViewport.ets', 'ReaderThumbnailRail.ets', 'ReaderSurface.ets', 'ReaderChrome.ets']) {
    const value = fs.readFileSync(path.join(root, file), 'utf8')
    assert.match(value, /readerElementKey\(/, file)
  }
  const pager = fs.readFileSync(path.join(root, 'ReaderPagerSurface.ets'), 'utf8')
  assert.match(pager, /LazyForEach\(this\.source,[\s\S]*readerElementKey\(key\)\)/)
})
