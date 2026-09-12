const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderImageCropDetector } = load('ReaderImageCrop')

function fixture(width, height, border, value) {
  const pixels = new Uint8Array(width * height * 4)
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const edge = x < border || x >= width - border || y < border || y >= height - border
    const offset = (y * width + x) * 4
    pixels[offset] = edge ? value : 112
    pixels[offset + 1] = edge ? value : 68
    pixels[offset + 2] = edge ? value : 184
    pixels[offset + 3] = 255
  }
  return pixels
}

test('shared crop detector conservatively detects white and black frames', () => {
  for (const value of [0, 255]) {
    const width = 40, height = 48
    const crop = ReaderImageCropDetector.detect(width, height, width * 4, fixture(width, height, 6, value))
    assert.equal(crop.applied(), true)
    assert.equal(crop.left, 5 / width)
    assert.equal(crop.right, 5 / width)
    assert.equal(crop.top, 5 / height)
    assert.equal(crop.bottom, 5 / height)
  }
})

test('shared crop detector keeps unframed and empty pages unchanged', () => {
  for (const border of [0, 40]) {
    const width = 32, height = 40
    assert.equal(ReaderImageCropDetector.detect(width, height, width * 4,
      fixture(width, height, border, 255)).applied(), false)
  }
})

test('shared crop detector preserves an edge containing more than one percent artwork', () => {
  const width = 40, height = 48, pixels = fixture(width, height, 6, 255)
  for (const x of [7, 8]) {
    const offset = x * 4
    pixels[offset] = 112; pixels[offset + 1] = 68; pixels[offset + 2] = 184
  }
  const crop = ReaderImageCropDetector.detect(width, height, width * 4, pixels)
  assert.equal(crop.top, 0)
  assert.ok(crop.left > 0 && crop.right > 0 && crop.bottom > 0)
})

test('shared crop detector rejects invalid RGBA input', () => {
  assert.equal(ReaderImageCropDetector.detect(40, 48, 40 * 4, new Uint8Array(5)).applied(), false)
})
