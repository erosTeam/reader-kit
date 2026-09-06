const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderViewportGeometry: Geometry, ReaderViewportTransform: Transform } = load('ReaderViewportTransform')
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 1e-8, `${actual} != ${expected}`)

test('focal pinch keeps the same content point under a moving finger center', () => {
  const g = new Geometry(400, 800, 400, 800, 4)
  const before = new Transform(2, 70, -180)
  const after = before.zoom(g, 3, 240, 310, 260, 330)
  near((240 - 200 - before.x) / before.scale, (260 - 200 - after.x) / after.scale)
  near((310 - 400 - before.y) / before.scale, (330 - 400 - after.y) / after.scale)
})

test('long-strip pan reaches both full original ends without drifting along the letterbox axis', () => {
  const g = new Geometry(440, 800, 40, 800, 20)
  const zoom = new Transform().zoom(g, 2, 220, 400)
  const top = zoom.pan(g, 10000, 10000)
  const bottom = top.pan(g, -10000, -20000)
  near(top.x, 0); near(bottom.x, 0)
  near((g.height - g.contentHeight * top.scale) / 2 + top.y, 0)
  near((g.height + g.contentHeight * bottom.scale) / 2 + bottom.y, g.height)
})

test('landscape joined content pans as one fitted frame, not two viewport-sized panes', () => {
  const g = new Geometry(440, 800, 440, 220, 3)
  const right = new Transform(2).pan(g, -10000, 10000)
  near(right.x, -220); near(right.y, 0)
  const left = right.pan(g, 20000, -20000)
  near(left.x, 220); near(left.y, 0)
})

test('dynamic max and elastic underscale use the established reader boundaries', () => {
  const g = new Geometry(400, 800, 400, 800, 20)
  near(g.maxScale(), 12)
  near(new Transform().zoom(g, 100, 200, 400).scale, 12)
  const underscale = new Transform().zoom(g, 0, 200, 400, 200, 400, true)
  near(underscale.scale, 0.8)
  assert.deepEqual(underscale.settled(g), new Transform())
  near(new Geometry(400, 800, 400, 800, 1).maxScale(), 4)
  near(new Transform().zoom(g, NaN, 200, 400).scale, 1)
})

test('double tap cycles primary/native/reset and skips an identical native stop', () => {
  const g = new Geometry(400, 800, 400, 800, 3)
  near(new Transform().doubleTapScale(g, false), 2)
  near(new Transform(2).doubleTapScale(g, false), 3)
  near(new Transform(3).doubleTapScale(g, false), 1)
  near(new Transform(2.3).doubleTapScale(g, true), 1)
  near(new Transform(2).doubleTapScale(new Geometry(400, 800, 400, 800, 2), false), 1)
})

test('button-driven selection can reset value without modifying an earlier gesture baseline', () => {
  const g = new Geometry(400, 800, 400, 800, 4)
  const baseline = new Transform(2, 30, -40)
  const moved = baseline.pan(g, 50, 100)
  assert.deepEqual(baseline, new Transform(2, 30, -40))
  assert.deepEqual(moved, new Transform(2, 80, 60))
  assert.deepEqual(new Transform().pan(g, 1000, 1000), new Transform())
})

test('resizing constrains old offsets to the newly measured viewport', () => {
  const resized = new Transform(2, 300, 600).settled(new Geometry(800, 400, 600, 400, 3))
  near(resized.x, 200); near(resized.y, 200)
  near(resized.scale, 2)
})

test('continuous long-row focal zoom uses row coordinates without moving its layout rectangle', () => {
  const g = new Geometry(416, 5342, 416, 5342, 720 / 416)
  const localPoint = { x: 150, y: 1100 }
  const zoomed = new Transform().zoom(g, 2, localPoint.x, localPoint.y)
  near((localPoint.x - g.width / 2 - zoomed.x) / zoomed.scale, localPoint.x - g.width / 2)
  near((localPoint.y - g.height / 2 - zoomed.y) / zoomed.scale, localPoint.y - g.height / 2)
  near(g.height, 5342)
  assert.deepEqual(zoomed.zoom(g, 1, localPoint.x, localPoint.y), new Transform())
})

test('continuous short-row zoom retains real image inset and bounds the image, not its neighboring rows', () => {
  const g = new Geometry(416, 220, 416, 127, 3)
  const moved = new Transform(2).pan(g, 10000, 10000)
  near(moved.x, 208); near(moved.y, 17)
  near((g.height - g.contentHeight * moved.scale) / 2 + moved.y, 0)
  near(g.height, 220); near(g.contentHeight, 127)
})
