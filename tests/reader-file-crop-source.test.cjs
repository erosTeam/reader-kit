const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const source = fs.readFileSync(path.resolve(__dirname,
  '../reader-ui/src/main/ets/ReaderFileCropSource.ets'), 'utf8')

test('file crop source samples off-thread, releases native images, and caches by host identity', () => {
  assert.match(source, /@Concurrent\s+async function detectReaderFileCrop/)
  assert.match(source, /taskpool\.execute<\[string\], string>\(detectReaderFileCrop, path\)/)
  assert.match(source, /await pixelMap\.release\(\)/)
  assert.match(source, /await source\.release\(\)/)
  assert.match(source, /const key = `\$\{this\.path\}\|\$\{this\.identity\}`/)
  assert.match(source, /READER_FILE_CROP_CACHE_LIMIT: number = 256/)
})
