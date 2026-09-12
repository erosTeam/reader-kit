const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const uiRoot = path.resolve(__dirname, '../reader-ui/src/main/ets')
const read = (name) => fs.readFileSync(path.join(uiRoot, name), 'utf8')

test('host interpolation reaches every original-image rendering branch', () => {
  const surface = read('ReaderSurface.ets')
  const pager = read('ReaderPagerSurface.ets')
  const viewport = read('ReaderPagedViewport.ets')
  const continuous = read('ReaderContinuousSurface.ets')
  const zoom = read('ReaderContinuousZoomImage.ets')

  assert.match(surface, /export struct ReaderSurface \{\s+@Param imageInterpolation:/)
  assert.match(surface, /ReaderContinuousSurface\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(surface, /ReaderPagerSurface\(\{\s+imageInterpolation: this\.imageInterpolation,/)

  assert.match(pager, /export struct ReaderPagerSurface \{\s+@Param imageInterpolation:/)
  assert.match(pager, /struct ReaderNativePager \{\s+@Param imageInterpolation:/)
  assert.match(pager, /ReaderNativePager\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(pager, /ReaderPagedViewport\(\{\s+imageInterpolation: this\.imageInterpolation,/)

  assert.match(viewport, /export struct ReaderPagedViewport \{\s+@Param imageInterpolation:/)
  assert.match(viewport, /struct ReaderPagedCell \{\s+@Param imageInterpolation:/)
  assert.match(viewport, /export struct ReaderPagedImage \{\s+@Param imageInterpolation:/)
  assert.match(viewport, /ReaderPagedCell\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(viewport, /ReaderPagedImage\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(viewport, /id\(`rkit-cropped-image-[^\n]+\)\s+\.interpolation\(this\.imageInterpolation\)/)
  assert.match(viewport, /\.interpolation\(this\.frame\.asset\.kind === 'original' \? this\.imageInterpolation : ImageInterpolation\.Low\)/)

  assert.match(continuous, /export struct ReaderContinuousSurface \{\s+@Param imageInterpolation:/)
  assert.match(continuous, /struct ReaderContinuousList \{\s+@Param imageInterpolation:/)
  assert.match(continuous, /struct ReaderContinuousCell \{\s+@Param imageInterpolation:/)
  assert.match(continuous, /ReaderContinuousList\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(continuous, /ReaderContinuousCell\(\{\s+imageInterpolation: this\.imageInterpolation,/)
  assert.match(continuous, /ReaderContinuousZoomImage\(\{\s+imageInterpolation: this\.imageInterpolation,/)

  assert.match(zoom, /export struct ReaderContinuousZoomImage \{\s+@Param imageInterpolation:/)
  assert.match(zoom, /ReaderPagedImage\(\{\s+imageInterpolation: this\.imageInterpolation,/)
})
