const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const vm = require('node:vm')
const path = require('node:path')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const code = ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderSystemImageSaveHost.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b }); return { promise, resolve, reject } }
function fixture() {
  const exports = {}, files = new Map([['/cache/hash.weird', 'image/png'], ['/cache/second', 'image/jpeg']])
  const fds = new Map(), dirs = new Set(), events = [], dialogs = []
  let id = 0
  const state = { copyGate: null, copyFailure: '', destinations: ['file://media/1', 'file://media/2'] }
  const io = {
    OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1 },
    openSync(p, mode) { events.push(['open', p]); if (mode === 0) assert.ok(files.has(p)); const f = { fd: ++id }; fds.set(f.fd, { p, data: files.get(p) }); return f },
    closeSync(f) { assert.ok(fds.delete(f.fd)); events.push(['close', f.fd]) },
    mkdtempSync(p) { const d = p.replace('XXXXXX', String(++id)); dirs.add(d); return d },
    async copyFile(a, b) {
      const source = typeof a === 'number' ? fds.get(a).data : files.get(a)
      const dest = typeof b === 'number' ? fds.get(b).p : b
      events.push(['copy', dest]); if (state.copyGate) await state.copyGate.promise
      if (dest === state.copyFailure) throw new Error('copy_failed')
      files.set(dest, source)
    },
    renameSync(a, b) { files.set(b, files.get(a)); files.delete(a) },
    unlinkSync(p) { events.push(['unlink', p]); files.delete(p) },
    rmdirSync(p) { dirs.delete(p) },
  }
  const modules = {
    '@kit.CoreFileKit': { fileIo: io, fileUri: { FileUri: class { constructor(uri) { assert.ok(uri.startsWith('file://')); this.path = uri.replace(/^file:\/\//, '') } }, getUriFromPath: p => 'file://' + p } },
    '@kit.ImageKit': { image: { createImageSource: p => ({ getImageInfo: async () => ({ mimeType: files.get(p) }), release: async () => events.push(['decoder-release']) }) } },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoType: { IMAGE: 1 }, getPhotoAccessHelper: () => ({
      async showAssetsCreationDialog(uris, configs) { dialogs.push({ uris, configs }); return typeof state.destinations === 'function' ? state.destinations() : state.destinations },
      release: async () => events.push(['helper-release']),
    }) } },
    '@reader-kit/core': { ReaderImageSaveItemResult: class { constructor(sourceIndex, status) { Object.assign(this, { sourceIndex, status }) } } },
  }
  vm.runInNewContext(code, { exports, require: name => { assert.ok(modules[name], name); return modules[name] }, console })
  const cancel = { cancelled: false, check() { if (this.cancelled) throw new Error('cancelled') } }
  const target = (uris = ['file:///cache/hash.weird', 'file:///cache/second']) => ({
    unit: { key: { work: '12345' } },
    items: uris.map((uri, sourceIndex) => ({ uri, sourceIndex })), copy() { return { unit: this.unit, items: this.items.map(x => ({ ...x })) } }
  })
  return { host: download => new exports.ReaderSystemImageSaveHost({ cacheDir: '/cache' }, download), target, cancel, files, fds, dirs, events, dialogs, state }
}
test('prepare captures all local FDs synchronously; independent copies use actual format and never show dialog', async () => {
  const f = fixture(); f.state.copyGate = deferred()
  const pending = f.host().prepare(f.target(), f.cancel)
  assert.equal(f.fds.size, 2); f.files.delete('/cache/hash.weird'); f.files.delete('/cache/second')
  f.state.copyGate.resolve(); const p = await pending
  assert.equal(f.dialogs.length, 0); assert.equal(f.fds.size, 0); assert.equal(f.dirs.size, 2)
  assert.ok([...f.files.keys()].some(x => x.endsWith('.png')))
  assert.ok([...f.files.keys()].some(x => x.endsWith('.jpg')))
  p.release(); p.release(); assert.equal(f.dirs.size, 0)
})
test('cancellation during copy waits for IO then removes only owned files', async () => {
  const f = fixture(); f.state.copyGate = deferred()
  const pending = f.host().prepare(f.target(), f.cancel)
  f.cancel.cancelled = true; assert.equal(f.dirs.size, 1)
  f.state.copyGate.resolve(); await assert.rejects(pending)
  assert.equal(f.dirs.size, 0); assert.equal(f.fds.size, 0); assert.equal(f.files.size, 2); assert.equal(f.dialogs.length, 0)
})
test('remote preparation invokes exact captured URI and cleans a partially failed download', async () => {
  const f = fixture(), uri = 'https://server/display?variant=shown'
  await assert.rejects(f.host(async (actual, p) => { assert.equal(actual, uri); f.files.set(p, 'partial'); throw Error('network') }).prepare(f.target([uri]), f.cancel))
  assert.equal(f.dirs.size, 0); assert.equal(f.files.size, 2); assert.equal(f.dialogs.length, 0)
})
test('one batch dialog, partial copy failure retains each page outcome and closes every FD', async () => {
  const f = fixture(); const p = await f.host().prepare(f.target(), f.cancel)
  f.state.copyFailure = 'file://media/1'
  const results = await p.present()
  assert.deepEqual(Array.from(results, x => x.status), ['failed', 'saved'])
  assert.equal(f.dialogs.length, 1); assert.equal(f.dialogs[0].uris.length, 2)
  assert.deepEqual(Array.from(f.dialogs[0].configs, x => x.fileNameExtension), ['png', 'jpg'])
  assert.deepEqual(Array.from(f.dialogs[0].configs, x => x.title), ['12345-1', '12345-2'])
  assert.equal(f.fds.size, 0); assert.equal(f.dirs.size, 2); p.release(); assert.equal(f.dirs.size, 0)
})
test('absolute paths bypass FileUri; titles retain safe work/page identity and bounded length', async () => {
  const f = fixture(), target = f.target(['/cache/hash.weird'])
  target.unit.key.work = '../work:name/' + 'a'.repeat(120)
  const p = await f.host().prepare(target, f.cancel); await p.present()
  const title = f.dialogs[0].configs[0].title
  assert.ok(title.startsWith('___work_name_')); assert.ok(title.endsWith('-1'))
  assert.ok(title.length <= 96); assert.match(title, /^[a-zA-Z0-9_-]+$/)
  p.release()
})
test('only common supported MIME mappings are admitted; extra decoded formats fail cleanly', async () => {
  for (const [mime, extension] of [['image/gif', 'gif'], ['image/webp', 'webp'], ['image/bmp', 'bmp'],
    ['image/heic', 'heic'], ['image/heif', 'heif'], ['image/svg+xml', null],
    ['image/x-icon', null], ['image/x-adobe-dng', null], ['image/tiff', null]]) {
    const f = fixture(); f.files.set('/cache/hash.weird', mime)
    if (extension) {
      const p = await f.host().prepare(f.target(['/cache/hash.weird']), f.cancel); await p.present()
      assert.equal(f.dialogs[0].configs[0].fileNameExtension, extension); p.release()
    } else await assert.rejects(f.host().prepare(f.target(['/cache/hash.weird']), f.cancel))
    assert.equal(f.dirs.size, 0); assert.equal(f.fds.size, 0)
  }
})
test('empty dialog result cancels all items; error codes are never opened as URIs', async () => {
  for (const destinations of [[], ['-3006', '-2004'], ['-203']]) {
    const f = fixture(); const p = await f.host().prepare(f.target(), f.cancel); f.state.destinations = destinations
    const results = await p.present()
    assert.deepEqual(Array.from(results, x => x.status), destinations.length ? ['failed', 'failed'] : ['cancelled', 'cancelled'])
    assert.equal(f.events.filter(x => x[0] === 'open' && x[1].startsWith('-')).length, 0); p.release()
  }
})
test('release while dialog or copy is pending does not delete its inputs early', async () => {
  const f = fixture(); const p = await f.host().prepare(f.target(), f.cancel), dialog = deferred()
  f.state.destinations = () => dialog.promise
  const pending = p.present(); p.release(); assert.equal(f.dirs.size, 2)
  f.state.copyGate = deferred(); dialog.resolve(['file://media/1', 'file://media/2'])
  await Promise.resolve(); await Promise.resolve(); assert.equal(f.dirs.size, 2)
  f.state.copyGate.resolve(); assert.deepEqual(Array.from(await pending, x => x.status), ['saved', 'saved'])
  assert.equal(f.dirs.size, 0); await assert.rejects(p.present())
})
test('unknown actual format, already cancelled and unavailable remote source leave no owned files', async () => {
  for (const mode of ['format', 'cancelled', 'remote']) {
    const f = fixture(); if (mode === 'format') f.files.set('/cache/hash.weird', 'unknown')
    if (mode === 'cancelled') f.cancel.cancelled = true
    await assert.rejects(f.host().prepare(mode === 'remote' ? f.target(['https://server/image']) : f.target(), f.cancel))
    assert.equal(f.dirs.size, 0); assert.equal(f.fds.size, 0); assert.equal(f.files.size, 2)
  }
})
