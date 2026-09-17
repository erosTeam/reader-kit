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

test('failure classification is a session port instead of a resource-decorator obligation', () => {
  const session = read('reader-core/src/main/ets/ReaderSession.ets')
  const probe = read('reader-ui/src/main/ets/ReaderLabAssetProbe.ets')
  assert.match(session, /interface ReaderAssetFailureClassifier[\s\S]*?classify\(error: Error\): ReaderAssetFailure/)
  assert.match(session, /private classifyFailure\(fallbackCode: string, error: Error \| null = null\): ReaderAssetFailure/)
  assert.match(session, /this\.failures\?\.classify\(error \?\? new Error\(fallbackCode\)\)/)
  assert.doesNotMatch(probe, /failure\(error: Error\)/)
})

test('decode and render failures carry the host classification too', () => {
  const session = read('reader-core/src/main/ets/ReaderSession.ets')
  assert.match(session, /this\.state\.failure = success \? null : this\.classifyFailure\('reader_decode_failed'\)/)
  assert.match(session, /reportRenderFailure[\s\S]*?this\.state\.failure = this\.classifyFailure\('reader_decode_failed'\)/)
})
