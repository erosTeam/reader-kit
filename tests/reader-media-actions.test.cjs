const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

function loadMediaActions() {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderMediaActions.ets'), 'utf8')
  const exports = {}
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports, require: name => {
    assert.equal(name, '@reader-kit/core')
    return {}
  } })
  return exports.ReaderMediaActions
}

test('media actions bundle keeps optional host ports independent of the reader session', () => {
  const ReaderMediaActions = loadMediaActions()
  const empty = new ReaderMediaActions()
  assert.equal(empty.imageShare, null)
  assert.equal(empty.imageSave, null)
  assert.equal(empty.informationSupplement, null)

  const share = { prepare() {} }
  const save = { prepare() {} }
  const information = () => ['host fact']
  const configured = new ReaderMediaActions(share, save, information)
  assert.equal(configured.imageShare, share)
  assert.equal(configured.imageSave, save)
  assert.equal(configured.informationSupplement, information)
})

test('surface exposes one media capability input instead of three parallel host props', () => {
  const source = fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')
  assert.match(source, /@Param mediaActions: ReaderMediaActions \| null = null/)
  assert.doesNotMatch(source, /@Param imageShare:/)
  assert.doesNotMatch(source, /@Param imageSave:/)
  assert.doesNotMatch(source, /@Param informationSupplement:/)
})
