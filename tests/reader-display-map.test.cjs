const assert = require('node:assert/strict')
const test = require('node:test')
const load = require('./load-core.cjs')
const { ReaderUnitKey, ReaderUnit, ReaderPage } = load('ReaderSession')
const { ReaderDisplayMap, ReaderDisplayPolicy, ReaderReadingAnchor } = load('ReaderDisplayMap')

const key = (unit = 'chapter-A', scope = 'source') => new ReaderUnitKey(scope, 'work', unit)
const unit = (count, id = key()) => new ReaderUnit(id, 'Chapter', count)
const page = (index, id = `page-${index}`, width = 800, height = 1200, owner = key()) => {
  const value = new ReaderPage(owner, id, index)
  value.width = width
  value.height = height
  return value
}
const policy = values => Object.assign(new ReaderDisplayPolicy(), values)
const pages = count => Array.from({ length: count }, (_, index) => page(index))
const topology = map => Array.from({ length: map.count() }, (_, index) =>
  map.item(index).parts.map(part => [part.sourceIndex, part.fragment]))

test('E/N pairing preserves first-page-alone and an unpaired final page', () => {
  for (const count of [0, 1, 2, 3, 4, 5, 6]) {
    for (const firstPageAlone of [false, true]) {
      const map = new ReaderDisplayMap(unit(count), pages(count), policy({ layout: 'spread', firstPageAlone }))
      const expected = []
      let index = 0
      if (firstPageAlone && count > 0) { expected.push([[0, 'whole']]); index = 1 }
      while (index < count) {
        expected.push(Array.from({ length: Math.min(2, count - index) }, (_, offset) => [index + offset, 'whole']))
        index += 2
      }
      assert.deepEqual(topology(map), expected)
    }
  }
})

test('RTL changes visual spread order, not source identity or logical navigation', () => {
  const map = new ReaderDisplayMap(unit(4), pages(4), policy({ layout: 'spread', direction: 'rtl' }))
  assert.deepEqual(map.item(0).parts.map(part => part.sourceIndex), [0, 1])
  assert.deepEqual(map.item(0).visualParts('rtl').map(part => part.sourceIndex), [1, 0])
  assert.equal(map.neighbor(0, 'next'), 1)
  assert.equal(map.neighbor(1, 'next'), null)
  assert.equal(map.neighbor(0, 'previous'), null)
  assert.equal(map.neighbor(1, 'previous'), 0)
})

test('Koma wide pages expand into separate half-page turns with direction-sensitive order', () => {
  const source = [page(0), page(1, 'wide', 1440, 1200)]
  for (const direction of ['ltr', 'rtl']) {
    const map = new ReaderDisplayMap(unit(2), source, policy({ splitWidePages: true, direction }))
    const sides = direction === 'rtl' ? ['right', 'left'] : ['left', 'right']
    assert.deepEqual(topology(map), [[[0, 'whole']], [[1, sides[0]]], [[1, sides[1]]]])
    assert.equal(map.isLastDisplayItem(1), false)
    assert.equal(map.isLastDisplayItem(2), true)
    assert.equal(map.neighbor(1, 'next'), 2)
    assert.equal(map.neighbor(2, 'next'), null)
  }
})

test('spread and continuous layouts do not apply the paged wide-splitting setting', () => {
  for (const layout of ['spread', 'continuous']) {
    const map = new ReaderDisplayMap(unit(2), [page(0, 'wide', 2000, 1000), page(1)],
      policy({ layout, splitWidePages: true }))
    assert.equal(map.count(), layout === 'spread' ? 1 : 2)
    assert.ok(topology(map).flat().every(([, fragment]) => fragment === 'whole'))
  }
})

test('long-strip originals and independent NH thumbnail dimensions remain unrelated', () => {
  const long = page(0, 'strip', 800, 18000)
  long.thumbnail.width = 2000
  long.thumbnail.height = 100
  const unknown = page(1, 'unknown', 0, 0)
  unknown.thumbnail.width = 2000
  unknown.thumbnail.height = 100
  const map = new ReaderDisplayMap(unit(2), [long, unknown], policy({ splitWidePages: true }))
  assert.deepEqual(topology(map), [[[0, 'whole']], [[1, 'whole']]])
})

test('late metadata can expand an earlier page without moving the anchored original', () => {
  const settings = policy({ splitWidePages: true })
  const before = new ReaderDisplayMap(unit(3), [page(2)], settings)
  const anchor = before.anchorAt(2, 0, 0.3, 0.65)
  const after = new ReaderDisplayMap(unit(3), [page(0, 'page-0', 2000, 1000), page(1), page(2)], settings)
  const restored = after.resolve(anchor)
  assert.equal(restored.match, 'page-key')
  assert.equal(restored.displayIndex, 3)
  assert.equal(restored.anchor.pageKey, 'page-2')
  assert.equal(restored.localY, 0.65)
})

test('stable key wins over the old index after source insertion', () => {
  const before = new ReaderDisplayMap(unit(2), [page(0, 'A'), page(1, 'B')])
  const anchor = before.anchorAt(1)
  const after = new ReaderDisplayMap(unit(3), [page(0, 'new'), page(1, 'A'), page(2, 'B')])
  const restored = after.resolve(anchor)
  assert.equal(restored.displayIndex, 2)
  assert.equal(restored.anchor.sourceIndexHint, 2)
  assert.equal(restored.anchor.pageKey, 'B')
})

test('an anchor on the second spread page survives single/spread/cover realignment', () => {
  const spread = new ReaderDisplayMap(unit(5), pages(5), policy({ layout: 'spread', direction: 'rtl' }))
  const anchor = spread.anchorAt(1, 1, 0.4, 0.8)
  const single = new ReaderDisplayMap(unit(5), pages(5))
  assert.equal(single.resolve(anchor).displayIndex, 3)
  const aligned = new ReaderDisplayMap(unit(5), pages(5), policy({ layout: 'spread', firstPageAlone: true }))
  const restored = aligned.resolve(anchor)
  assert.equal(restored.displayIndex, 2)
  assert.equal(restored.partIndex, 0)
  assert.equal(restored.anchor.pageKey, 'page-3')
  assert.equal(restored.localY, 0.8)
})

test('split anchor preserves physical half and page coordinates across collapse and RTL', () => {
  const source = [page(0, 'wide', 2000, 1000)]
  const before = new ReaderDisplayMap(unit(1), source, policy({ splitWidePages: true }))
  const anchor = before.anchorAt(1, 0, 0.2, 0.75)
  assert.equal(anchor.fragment, 'right')
  assert.equal(anchor.x, 0.6)
  const whole = new ReaderDisplayMap(unit(1), source)
  const collapsed = whole.resolve(anchor)
  assert.equal(collapsed.localX, 0.6)
  assert.equal(collapsed.anchor.fragment, 'right')
  const rtl = new ReaderDisplayMap(unit(1), source, policy({ splitWidePages: true, direction: 'rtl' }))
  const restored = rtl.resolve(collapsed.anchor)
  assert.equal(restored.displayIndex, 0)
  assert.ok(Math.abs(restored.localX - 0.2) < 1e-12)
  assert.equal(restored.localY, 0.75)
})

test('whole-page anchor uses its point when splitting; center starts at the reading-side half', () => {
  const source = [page(0, 'wide', 2000, 1000)]
  for (const direction of ['ltr', 'rtl']) {
    const map = new ReaderDisplayMap(unit(1), source, policy({ splitWidePages: true, direction }))
    const right = map.resolve(new ReaderReadingAnchor(key(), 'wide', 0, 0.8, 0.2))
    assert.equal(map.item(right.displayIndex).parts[0].fragment, 'right')
    const center = map.resolve(new ReaderReadingAnchor(key(), 'wide', 0))
    assert.equal(center.displayIndex, 0)
  }
})

test('sparse metadata is not guessed: a known missing identity waits, then explicitly fails', () => {
  const anchor = new ReaderReadingAnchor(key(), 'old', 1)
  const sparse = new ReaderDisplayMap(unit(3), [page(1, 'replacement')])
  assert.equal(sparse.resolve(anchor).match, 'pending-metadata')
  assert.equal(sparse.resolve(anchor).resolved(), false)
  const complete = new ReaderDisplayMap(unit(3), pages(3))
  assert.equal(complete.resolve(anchor).match, 'missing-page')
  const fallback = complete.resolve(anchor, true)
  assert.equal(fallback.match, 'index-fallback')
  assert.equal(fallback.anchor.pageKey, 'page-1')
})

test('a newly resolved half becomes the next anchor, including the exact center seam', () => {
  const source = [page(0, 'wide', 2000, 1000)]
  const ltr = new ReaderDisplayMap(unit(1), source, policy({ splitWidePages: true }))
  const selected = ltr.resolve(new ReaderReadingAnchor(key(), 'wide', 0))
  assert.equal(selected.anchor.fragment, 'left')
  const rtl = new ReaderDisplayMap(unit(1), source, policy({ splitWidePages: true, direction: 'rtl' }))
  const restored = rtl.resolve(selected.anchor)
  assert.equal(restored.displayIndex, 1)
  assert.equal(restored.anchor.fragment, 'left')
  assert.equal(restored.localX, 1)
})

test('unresolved metadata uses an explicit index hint, and adopts the stable key when available', () => {
  const sparse = new ReaderDisplayMap(unit(3), [])
  const anchor = sparse.anchorAt(2)
  assert.equal(anchor.pageKey, null)
  const hydrated = new ReaderDisplayMap(unit(3), pages(3))
  const restored = hydrated.resolve(anchor)
  assert.equal(restored.match, 'index-hint')
  assert.equal(restored.anchor.pageKey, 'page-2')
})

test('chapter and account identity fences forbid index fallback across a unit boundary', () => {
  const anchor = new ReaderDisplayMap(unit(1), pages(1)).anchorAt(0)
  for (const owner of [key('chapter-B'), key('chapter-A', 'other-account')]) {
    const map = new ReaderDisplayMap(unit(1, owner), [page(0, 'page-0', 800, 1200, owner)])
    assert.equal(map.resolve(anchor, true).match, 'wrong-unit')
    assert.equal(map.resolve(anchor, true).resolved(), false)
  }
})

test('map owns constructor inputs and returns detached items and anchors', () => {
  const catalog = unit(2)
  const source = pages(2)
  const settings = policy({ layout: 'spread' })
  const map = new ReaderDisplayMap(catalog, source, settings)
  catalog.key.unit = 'mutated'
  source[0].key = 'mutated'
  settings.direction = 'rtl'
  map.item(0).parts[0].unit.scope = 'mutated'
  map.item(0).parts.pop()
  const anchor = map.anchorAt(0)
  const resolution = map.resolve(anchor)
  resolution.anchor.unit.scope = 'mutated'
  assert.equal(map.count(), 1)
  assert.equal(map.item(0).parts.length, 2)
  assert.equal(map.resolve(anchor).match, 'page-key')
})

test('invalid metadata is rejected; empty units and invalid UI indexes never point at a page', () => {
  assert.throws(() => new ReaderDisplayMap(unit(2), [page(0), page(0)]), /invalid_page_metadata/)
  assert.throws(() => new ReaderDisplayMap(unit(2), [page(0, 'same'), page(1, 'same')]), /invalid_page_metadata/)
  assert.throws(() => new ReaderDisplayMap(unit(1), [page(1)]), /invalid_page_metadata/)
  assert.throws(() => new ReaderDisplayMap(unit(1), [page(0, 'x', 1, 1, key('other'))]), /invalid_page_metadata/)
  assert.throws(() => new ReaderDisplayMap(unit(-1), []), /invalid_page_count/)
  const empty = new ReaderDisplayMap(unit(0), [])
  assert.equal(empty.resolve(new ReaderReadingAnchor(key(), null, 0)).match, 'empty')
  assert.equal(empty.isLastDisplayItem(-1), false)
  const map = new ReaderDisplayMap(unit(2), pages(2))
  for (const index of [-1, NaN, Infinity, 0.5, 2]) {
    assert.equal(map.item(index), null)
    assert.equal(map.anchorAt(index), null)
    assert.equal(map.neighbor(index, 'next'), null)
  }
})
