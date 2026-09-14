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

test('absent or invalid entry overrides preserve legacy defaults without forcing host policy', () => {
  const api = fixture()
  const direct = new api.ReaderLabRequest('work', 'unit', 2)
  assert.equal(direct.entryLayoutOverride, null)
  assert.equal(direct.entryDirectionOverride, null)
  for (const input of [undefined, null, '', true, 0, 'vertical', 'RTL']) {
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabPage: 2,
      readerLabEntryLayout: input, readerLabEntryDirection: input } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.entryLayoutOverride, null)
    assert.equal(request.entryDirectionOverride, null)
    assert.equal(request.rotateWidePagesOverride, null)
    assert.equal(request.entryLayout, 'single')
    assert.equal(request.entryDirection, 'ltr')
    assert.equal(request.pageIndex, 2)
  }
})

test('wide-page rotation override is strict, independent and absent by default', () => {
  const direct = new (fixture().ReaderLabRequest)('work', 'unit', 0)
  assert.equal(direct.rotateWidePagesOverride, null)
  for (const [input, expected] of [[true, true], ['true', true], [false, false], ['false', false]]) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabRotateWidePages: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().rotateWidePagesOverride, expected)
  }
  for (const input of [undefined, null, 0, 1, '', 'TRUE', 'invalid']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabRotateWidePages: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().rotateWidePagesOverride, null)
  }
})

test('entry overrides are independent and preserve explicit single, spread, continuous and ltr', () => {
  const api = fixture()
  for (const layout of ['single', 'spread', 'continuous', undefined]) for (const direction of ['ltr', 'rtl', undefined]) {
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work',
      readerLabEntryLayout: layout, readerLabEntryDirection: direction } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.entryLayoutOverride, layout ?? null)
    assert.equal(request.entryDirectionOverride, direction ?? null)
    assert.equal(request.entryLayout, layout === 'spread' ? 'spread' : 'single')
    assert.equal(request.entryDirection, direction ?? 'ltr')
  }
})

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

test('progress persistence requires an explicit full-reader debug request', () => {
  const direct = new (fixture().ReaderLabRequest)('work', 'unit', 0)
  assert.equal(direct.progressReadWrite, false)
  for (const input of [undefined, null, false, 'false', 1, 'TRUE']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabProgressReadWrite: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().progressReadWrite, false)
  }
  for (const input of [true, 'true']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabProgressReadWrite: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().progressReadWrite, true)
  }
  const api = fixture()
  api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: false,
    readerLabProgressReadWrite: true } }, true)
  assert.equal(api.connectReaderLabLaunch().consume().progressReadWrite, false)
})

test('preference persistence is independently gated by an explicit full-reader debug request', () => {
  const direct = new (fixture().ReaderLabRequest)('work', 'unit', 0)
  assert.equal(direct.preferencesReadWrite, false)
  for (const input of [undefined, null, false, 'false', 1, 'TRUE']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabPreferencesReadWrite: input, readerLabProgressReadWrite: true } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.preferencesReadWrite, false)
    assert.equal(request.progressReadWrite, true)
  }
  for (const input of [true, 'true']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabPreferencesReadWrite: input } }, true)
    const request = api.connectReaderLabLaunch().consume()
    assert.equal(request.preferencesReadWrite, true)
    assert.equal(request.progressReadWrite, false)
  }
  const api = fixture()
  api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: false,
    readerLabPreferencesReadWrite: true } }, true)
  assert.equal(api.connectReaderLabLaunch().consume().preferencesReadWrite, false)
})

test('page override presence distinguishes an explicit debug page from host progress restore', () => {
  const direct = new (fixture().ReaderLabRequest)('work', 'unit', 0)
  assert.equal(direct.pageIndexProvided, false)
  for (const input of [0, 2, -1, '0', ' 3 ']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabPage: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().pageIndexProvided, true)
  }
  for (const input of [undefined, null, '', ' ', true, 'not-a-page', Number.NaN]) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabPage: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().pageIndexProvided, false)
  }
})

test('chapter handoff probes require full-reader debug mode and accept only bounded one-shot values', () => {
  const direct = new (fixture().ReaderLabRequest)('work', 'unit', 0)
  assert.equal(direct.chapterProbe, '')
  for (const input of [undefined, null, '', true, 'fail', 'delay-once']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabChapterProbe: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().chapterProbe, '')
  }
  for (const input of ['prepare-fail-once', 'prepare-delay-once']) {
    const api = fixture()
    api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: true,
      readerLabChapterProbe: input } }, true)
    assert.equal(api.connectReaderLabLaunch().consume().chapterProbe, input)
  }
  const api = fixture()
  api.captureReaderLabWant({ parameters: { readerLabWork: 'work', readerLabChrome: false,
    readerLabChapterProbe: 'prepare-fail-once' } }, true)
  assert.equal(api.connectReaderLabLaunch().consume().chapterProbe, '')
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
