const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderImageShareTarget, ReaderImageShareController } = load('ReaderImageShare')
const { ReaderUnit, ReaderUnitKey } = load('ReaderContent')
const { ReaderPagedSnapshot } = load('ReaderPagedSession')
const { ReaderReadingAnchor } = load('ReaderDisplayMap')
const unit = () => new ReaderUnit(new ReaderUnitKey('source', 'work', 'chapter'), 'Title', 10)
const target = (page = 1, navigation = 2) => new ReaderImageShareTarget(unit(), page, navigation)
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b }); return { promise, resolve, reject } }
const ready = () => { const c = new ReaderImageShareController(); c.update(target(), true); return c }

test('share target follows original anchor, copies identity, ignores RTL frame order', () => {
  const s = new ReaderPagedSnapshot()
  s.unit = unit(); s.phase = 'ready'; s.navigationRevision = 7
  s.anchor = new ReaderReadingAnchor(s.unit.key, 'page2', 1)
  s.frames = [{ sourceIndex: 2 }, { sourceIndex: 1 }]
  const t = ReaderImageShareTarget.from(s)
  assert.equal(t.sourceIndex, 1); assert.equal(t.navigation, 7)
  s.unit.key.unit = 'replaced'
  assert.equal(t.unit.key.unit, 'chapter')
  s.phase = 'closed'
  assert.equal(ReaderImageShareTarget.from(s), null)
})

test('late preparation after page change never presents and cannot clear a newer operation', async () => {
  const c = ready(), first = deferred(), second = deferred(), dismissal = deferred()
  let shown = 0, released = 0
  const p = { present: async () => { shown++ }, release: () => released++ }
  const old = c.share({ prepare: () => first.promise })
  c.update(target(2, 3), true)
  const fresh = c.share({ prepare: () => second.promise })
  first.resolve(p)
  assert.equal(await old, 'cancelled'); assert.equal(shown, 0); assert.equal(released, 1)
  assert.equal(c.busy(), true)
  second.resolve({ present: () => { shown++; return dismissal.promise }, release: () => released++ })
  await Promise.resolve(); assert.equal(shown, 1); assert.equal(c.busy(), true)
  dismissal.resolve(); assert.equal(await fresh, 'dismissed'); assert.equal(released, 2)
  assert.equal(c.busy(), false)
})

test('route deactivation cancels preparation even if the same page later resumes', async () => {
  const c = ready(), pending = deferred()
  let token, shown = 0, released = 0
  const run = c.share({ prepare: (_, cancellation) => { token = cancellation; return pending.promise } })
  c.update(target(), false); c.update(target(), true)
  assert.equal(token.isCancelled(), true)
  pending.resolve({ present: async () => { shown++ }, release: () => released++ })
  assert.equal(await run, 'cancelled'); assert.equal(shown, 0); assert.equal(released, 1)
})

test('visible presentation rejects duplicates and retains resources through background and disposal until dismiss', async () => {
  const c = ready(), dismissal = deferred()
  let prepared = 0, released = 0
  const busy = []
  c.subscribe(value => busy.push(value))
  const host = { prepare: async () => { prepared++; return { present: () => dismissal.promise, release: () => released++ } } }
  const run = c.share(host)
  await Promise.resolve()
  assert.equal(await c.share(host), 'ignored'); assert.equal(prepared, 1)
  c.update(target(), false); assert.equal(c.busy(), true); assert.equal(released, 0)
  c.close(); assert.equal(released, 0)
  dismissal.resolve(); assert.equal(await run, 'dismissed'); assert.equal(released, 1)
  assert.deepEqual(busy, [false, true])
})

test('prepare/show failure returns failure and permits a fresh request; stale errors stay silent', async () => {
  const c = ready()
  assert.equal(await c.share({ prepare: async () => { throw new Error('network') } }), 'failed')
  let released = 0
  assert.equal(await c.share({ prepare: async () => ({ present: async () => { throw new Error('show') }, release: () => released++ }) }), 'failed')
  assert.equal(released, 1); assert.equal(c.busy(), false)
  const pending = deferred(), run = c.share({ prepare: () => pending.promise })
  c.close(); pending.reject(new Error('late'))
  assert.equal(await run, 'cancelled'); assert.equal(await c.share({}), 'ignored')
})
