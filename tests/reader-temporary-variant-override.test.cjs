const assert = require('node:assert/strict')
const { test } = require('node:test')
const load = require('./load-core.cjs')

const { ReaderPage, ReaderUnitKey } = load('ReaderContent')
const { ReaderVariantPreference } = load('ReaderSession')
const { ReaderTemporaryVariantOverride, ReaderTemporaryVariantScope } = load('ReaderTemporaryVariantOverride')

function scope(navigationRevision = 7, pageKey = 'page-0') {
  const unit = new ReaderUnitKey('source', 'gallery', 'unit')
  return ReaderTemporaryVariantScope.fromPages(unit, navigationRevision, [
    new ReaderPage(unit, pageKey, 0),
    new ReaderPage(unit, 'page-1', 1),
  ])
}

test('temporary override is canonical-current-unit only and keeps non-enhanced variants intact', () => {
  const override = new ReaderTemporaryVariantOverride()
  const current = scope()
  const enhanced = new ReaderVariantPreference('enhanced', 'model:4x')
  const translated = new ReaderVariantPreference('translated', 'translator:zh')

  assert.equal(override.toggle(current), false)
  assert.equal(override.revision, 1)
  assert.equal(override.preference(current, 0, 'page-0', enhanced).variant, 'default')
  assert.equal(override.preference(current, 1, 'page-1', enhanced).variant, 'default')
  assert.equal(override.preference(current, 0, 'rebuilt-page-0', enhanced).variant, 'enhanced')
  assert.equal(override.preference(current, 0, 'page-0', translated).variant, 'translated')

  const nextUnit = scope(8)
  override.reconcile(nextUnit)
  assert.equal(override.isDisabled(nextUnit), false)
  assert.equal(override.revision, 2)
  assert.equal(override.preference(nextUnit, 0, 'page-0', enhanced).variant, 'enhanced')
})

test('re-toggle restores processing only for the same current unit scope', () => {
  const override = new ReaderTemporaryVariantOverride()
  const current = scope()
  assert.equal(override.toggle(current), false)
  assert.equal(override.toggle(current.copy()), true)
  assert.equal(override.revision, 2)
  assert.equal(override.isDisabled(current), false)
})
