const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const uiRoot = path.resolve(__dirname, '../reader-ui/src/main/ets')
const continuous = fs.readFileSync(path.join(uiRoot, 'ReaderContinuousSurface.ets'), 'utf8')
const zoom = fs.readFileSync(path.join(uiRoot, 'ReaderContinuousZoomImage.ets'), 'utf8')

test('continuous original rows derive height from full available width and intrinsic ratio', () => {
  assert.match(continuous, /private imageAspectRatio\(index: number\): number/)
  assert.match(continuous, /const ratio = width > 0 && height > 0 \? width \/ height \/ heightRatio : 0\.75/)
  assert.match(continuous, /imageAspectRatio: this\.imageAspectRatio\(this\.snapshot\.displayKeys\.indexOf\(key\)\)/)
  assert.match(continuous, /\.width\('100%'\)\.aspectRatio\(this\.imageAspectRatio\)/)
  assert.doesNotMatch(continuous, /ListItem\(\)[\s\S]{0,1800}\.height\(this\.rowHeight/)
})

test('continuous image fills its ratio-sized row while failures remain compact', () => {
  assert.match(zoom, /\.width\('100%'\)\.height\('100%'\)/)
  assert.doesNotMatch(zoom, /\.width\('100%'\)\.height\(this\.imageHeight\)/)
  assert.match(continuous, /\.width\('100%'\)\.height\(220\)\.id\(`rkit-continuous-page-/)
})

test('continuous list applies the same bounded host page gap without changing image ratios', () => {
  assert.match(continuous, /space: normalizedReaderPageGap\(this\.pageGap\)/)
  assert.match(continuous, /@Param pageGap: number = 0/)
})
