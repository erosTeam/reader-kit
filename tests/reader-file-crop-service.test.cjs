const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { createHash } = require('node:crypto')
const load = require('./load-core.cjs')
const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const core = { ...load('ReaderPageCropBounds'), ...load('ReaderImageCrop') }
const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderFileCropService.ets'), 'utf8')
function fixture({ execute, image = {} }) {
  let bytes = Buffer.from('first image bytes'), handles = 0
  const offsets = new Map(), exported = {}
  const imports = {
    '@reader-kit/core': core,
    '@kit.ArkTS': { taskpool: { async execute(fn, ...args) {
      return fn.name === 'hashReaderFileCrop' ? fn(...args) : execute(fn, ...args)
    } } },
    '@kit.ImageKit': { image },
    '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_ONLY: 0 },
      openSync() { const fd = ++handles; offsets.set(fd, 0); return { fd } },
      readSync(fd, buffer) {
        const offset = offsets.get(fd), part = bytes.subarray(offset, offset + buffer.byteLength)
        new Uint8Array(buffer).set(part); offsets.set(fd, offset + part.length); return part.length
      }, closeSync(file) { offsets.delete(file.fd) },
    } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd() {
      const digest = createHash('sha256')
      return { updateSync(value) { digest.update(value.data) }, digestSync() { return { data: digest.digest() } } }
    } } },
  }
  vm.runInNewContext(ts.transpileModule(source.replace(/^@Concurrent\r?\n/gm, '') +
    '\nexport { detectReaderFileCrop }', { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
    } }).outputText, { exports: exported, require: name => imports[name] ?? {} })
  const port = {}
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../reader-ui/src/main/ets/ReaderFileCropSource.ets'), 'utf8'), { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
    } }).outputText, { exports: port, require: name => name === '@reader-kit/core' ? core : exported })
  return { ...exported, ...port, offsets, changeBytes: value => { bytes = Buffer.from(value) } }
}

test('content identity reuses warmed bounds but not replaced bytes or another crop strength', async () => {
  let executions = 0
  const f = fixture({ execute() { executions++; return '100,100,0.1,0.2,0.3,0.4' } })
  await Promise.all([f.ReaderFileCropService.detectFile('/same-path.webp', 'standard'),
    f.ReaderFileCropService.detectFile('/same-path.webp', 'standard')])
  await f.ReaderFileCropService.detectFile('/same-path.webp', 'standard')
  assert.equal(executions, 1, 'a displayed asset reuses its warmed bounds')
  f.changeBytes('other image bytes')
  await f.ReaderFileCropService.detectFile('/same-path.webp', 'standard')
  assert.equal(executions, 2, 'changed bytes cannot reuse stale geometry')
  await f.ReaderFileCropService.detectFile('/same-path.webp', 'strong')
  assert.equal(executions, 3)
  assert.equal(f.offsets.size, 0, 'identity readers close their file handles')
})

test('packed RGBA crop is independent of native alignment; legacy policy and failed reads stay bounded', async () => {
  // Issue #20 device counterexample: 171x256 RGBA, native stride 768, export length 175104.
  const packed = new Uint8Array(171 * 256 * 4).fill(255)
  for (let y = 37; y < 219; y++) for (let x = 24; x < 147; x++) {
    const offset = (y * 171 + x) * 4
    packed[offset] = 60; packed[offset + 1] = 90; packed[offset + 2] = 120
  }
  let nativeStride = 684, releasedPixels = 0, releasedSources = 0, failRead = false
  const f = fixture({ execute: (fn, ...args) => fn(...args), image: {
    PixelMapFormat: { RGBA_8888: 3 }, createImageSource() { return {
      async getImageInfo() { return { size: { width: 1280, height: 1920 } } },
      async createPixelMap() { return {
        async getImageInfo() { return { size: { width: 171, height: 256 }, stride: nativeStride } },
        getPixelBytesNumber() { return packed.byteLength },
        async readPixelsToBuffer(buffer) { if (failRead) throw Error('read failed'); new Uint8Array(buffer).set(packed) },
        async release() { releasedPixels++ },
      } }, async release() { releasedSources++ },
    } },
  } })
  const tight = core.ReaderPageCropBounds.parse(await f.detectReaderFileCrop('/tight.png', 'standard'))
  nativeStride = 768
  const aligned = core.ReaderPageCropBounds.parse(await f.detectReaderFileCrop('/aligned.png', 'standard'))
  assert.equal(tight.applied(), true)
  assert.equal(aligned.applied(), true, 'native alignment must not reject a valid packed export')
  assert.equal(aligned.serialize(), tight.serialize(), 'same exported pixels must produce the same crop')
  const port = new f.ReaderFileCropSource('file:///aligned.png', 'asset')
  const legacy = await port.read()
  assert.deepEqual(legacy, core.ReaderImageCropDetector.detect(171, 256, 684, packed))
  legacy.left = 0
  assert.deepEqual(await new f.ReaderFileCropSource('/aligned.png', 'asset').read(),
    core.ReaderImageCropDetector.detect(171, 256, 684, packed), 'legacy callers own independent returned bounds')
  const strong = await f.ReaderFileCropService.detect('/aligned.png', 'asset', 'strong')
  assert.deepEqual([strong.left,strong.top,strong.right,strong.bottom],
    [aligned.left,aligned.top,aligned.right,aligned.bottom])
  failRead = true
  assert.equal((await f.ReaderFileCropService.detect('/failure.png', 'asset')).applied(), false)
  assert.equal(releasedPixels, 5)
  assert.equal(releasedSources, 5)
})
