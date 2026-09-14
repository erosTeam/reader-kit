const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '../reader-ui/src/main/ets')
const panel = fs.readFileSync(path.join(root, 'ReaderAssetNoticePanel.ets'), 'utf8')
const paged = fs.readFileSync(path.join(root, 'ReaderPagedViewport.ets'), 'utf8')
const continuous = fs.readFileSync(path.join(root, 'ReaderContinuousSurface.ets'), 'utf8')
const surface = fs.readFileSync(path.join(root, 'ReaderSurface.ets'), 'utf8')

test('suppressed content uses a host-authored preview panel in both reader layouts', () => {
  assert.match(panel, /Image\(this\.notice\.previewUri\)/)
  assert.match(panel, /objectFit\(ImageFit\.Cover\)/)
  assert.match(panel, /\.blur\(18\)/)
  assert.match(panel, /linearGradient\(/)
  assert.match(panel, /id\(`rkit-notice-page-\$\{this\.page\}`\)/)
  assert.match(panel, /height\(36\).*minWidth: 104/s)
  assert.match(paged, /asset\.phase === 'suppressed'.*ReaderAssetNoticePanel/s)
  assert.match(continuous, /asset\.phase === 'suppressed'.*ReaderAssetNoticePanel/s)
})

test('notice recovery carries topology, navigation, item, slot, request and notice identity', () => {
  assert.match(surface, /resolveNoticeItem\(topology, navigation, key, slot, request, noticeId\)/)
  assert.match(paged, /onNoticeAction\(this\.slotId, frame\.asset\.assetRequestId, notice\.id\)/)
  assert.match(continuous, /this\.onNoticeAction\(this\.createdRevision, this\.snapshot\.navigationRevision,/)
})
