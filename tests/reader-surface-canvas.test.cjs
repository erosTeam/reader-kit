const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const surface = fs.readFileSync(path.join(__dirname,
  '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')

test('reader surface keeps an independently fading host canvas behind a retireable body', () => {
  assert.match(surface, /@Param canvasBackground: ResourceColor = Color\.Black/)
  assert.match(surface, /@Param canvasForeground: ResourceColor = Color\.White/)
  assert.match(surface, /@Param canvasBackdropOpacity: number = 1/)
  assert.match(surface, /@Param bodyOpacity: number = 1/)
  assert.match(surface, /fontColor\(this\.canvasForeground\)/)
  assert.match(surface, /backgroundColor\(this\.canvasBackground\)\s*\.opacity\(this\.canvasBackdropOpacity\)/)
  assert.match(surface, /\.opacity\(this\.bodyOpacity\)/)
  assert.match(surface, /backgroundColor\(Color\.Transparent\)\.id\('rkit-reading-surface'\)/)
  assert.doesNotMatch(surface, /backgroundColor\(Color\.Black\)\.id\('rkit-reading-surface'\)/)
})
