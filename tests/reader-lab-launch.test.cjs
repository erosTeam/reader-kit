const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderLabLaunch.ets'), 'utf8')

function fixture() {
  const exportsUI = {}
  let state
  vm.runInNewContext(ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true },
  }).outputText, {
    exports: exportsUI,
    ObservedV2: value => value,
    Trace: () => {},
    require: name => {
      assert.equal(name, '@kit.ArkUI')
      return { AppStorageV2: { connect: (_type, create) => state ??= create() } }
    },
  })
  return exportsUI
}

test('volume default preserves legacy false and leaves override unspecified', () => {
  const api = fixture()
  const direct = new api.ReaderLabRequest('work', 'unit', 0)
  assert.equal(direct.volumeKeys, false)
  assert.equal(direct.volumeKeysOverride, null)
  api.captureReaderLabWant({ parameters: { readerLabWork: 'work' } }, true)
  const request = api.connectReaderLabLaunch().consume()
  assert.equal(request.volumeKeys, false)
  assert.equal(request.volumeKeysOverride, null)
})

test('strict boolean and string overrides retain legacy interpretation', () => {
  for (const [input, expected] of [[true, true], ['true', true], [false, false], ['false', false]]) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabVolumeKeys: input } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.volumeKeys, expected)
    assert.equal(request.volumeKeysOverride, expected)
  }
})

test('invalid values do not become an explicit disable override', () => {
  for (const input of [null, undefined, 0, 1, '', 'TRUE', 'invalid']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabVolumeKeys: input } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.volumeKeys, false)
    assert.equal(request.volumeKeysOverride, null)
  }
})

test('non-debug wants publish nothing and do not replace a pending request', () => {
  const api = fixture(), state = api.connectReaderLabLaunch()
  api.captureReaderLabWant({ parameters: { readerLabWork: 'ignored', readerLabVolumeKeys: true } }, false)
  assert.equal(state.consume(), null)
  assert.equal(state.version, 0)
  api.captureReaderLabWant({ parameters: { readerLabWork: 'accepted', readerLabVolumeKeys: false } }, true)
  api.captureReaderLabWant({ parameters: { readerLabWork: 'ignored', readerLabVolumeKeys: true } }, false)
  const request = state.consume()
  assert.equal(request.work, 'accepted')
  assert.equal(request.volumeKeysOverride, false)
  assert.equal(state.version, 1)
})

test('consuming successive requests clears pending state without leaking overrides', () => {
  const api = fixture(), state = api.connectReaderLabLaunch()
  api.captureReaderLabWant({ parameters: { readerLabWork: 'first', readerLabVolumeKeys: true } }, true)
  const first = state.consume()
  assert.equal(first.volumeKeysOverride, true)
  assert.equal(state.consume(), null)
  api.captureReaderLabWant({ parameters: { readerLabWork: 'second' } }, true)
  const second = state.consume()
  assert.notEqual(first, second)
  assert.equal(second.work, 'second')
  assert.equal(second.volumeKeys, false)
  assert.equal(second.volumeKeysOverride, null)
  assert.equal(first.volumeKeysOverride, true)
  assert.equal(state.consume(), null)
  assert.equal(state.version, 2)
})
