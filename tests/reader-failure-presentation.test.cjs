const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8')

test('failure panel prefers host-classified text while retaining generic fallbacks', () => {
  const panel = read('reader-ui/src/main/ets/ReaderFailurePanel.ets')
  assert.match(panel, /@Param failure: ReaderAssetFailure \| null = null/)
  assert.match(panel, /failure\.title\.length > 0[\s\S]*?rkit_image_failed/)
  assert.match(panel, /failure\.hint\.length > 0[\s\S]*?rkit_image_retry_hint/)
})

test('paged and continuous failure cells forward their exact asset classification', () => {
  const paged = read('reader-ui/src/main/ets/ReaderPagedViewport.ets')
  const continuous = read('reader-ui/src/main/ets/ReaderContinuousSurface.ets')
  assert.match(paged, /ReaderFailurePanel\(\{[\s\S]*?failure: this\.frame\(\)\.asset\.failure/)
  assert.match(continuous, /ReaderFailurePanel\(\{[\s\S]*?failure: frame\.asset\.failure/)
})

test('lab provider preserves host classification instead of replacing it', () => {
  const probe = read('reader-ui/src/main/ets/ReaderLabAssetProbe.ets')
  assert.match(probe, /failure\(error: Error\): ReaderAssetFailure[\s\S]*?this\.provider\.failure\?\.\(error\)/)
})
