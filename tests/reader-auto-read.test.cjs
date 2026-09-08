const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderAutoReadController } = load('ReaderAutoRead')
const { ReaderUnit, ReaderUnitKey, ReaderPage } = load('ReaderContent')
const { ReaderSnapshot } = load('ReaderSession')
const { ReaderPagedSnapshot, ReaderPagedFrame } = load('ReaderPagedSession')
const { ReaderDisplayMap } = load('ReaderDisplayMap')
function snapshot(index = 0, layout = 'spread', count = 6) {
  const s = new ReaderPagedSnapshot()
  s.unit = new ReaderUnit(new ReaderUnitKey('s', 'w', 'u'), 'title', count)
  s.phase = 'ready'; s.policy.layout = layout; s.policy.direction = 'rtl'; s.displayIndex = index
  s.pageMetadata = Array.from({length: count}, (_, i) => new ReaderPage(s.unit.key, `p${i}`, i))
  const map = new ReaderDisplayMap(s.unit, s.pageMetadata, s.policy); s.displayCount = map.count()
  s.frames = map.item(index).visualParts('rtl').map(part => {
    const a = new ReaderSnapshot(); a.unit = s.unit.copy(); a.page = s.pageMetadata[part.sourceIndex].copy()
    a.sourceIndex = part.sourceIndex; a.phase = 'displayed'; a.uri = `file://${part.pageKey}`; a.assetRequestId = part.sourceIndex + 1
    return new ReaderPagedFrame(part.sourceIndex + 1, part, a)
  })
  return s
}
function fixture() {
  let id = 0, calls = 0
  const timers = new Map(), cancelled = []
  const c = new ReaderAutoReadController(() => { calls++; return true }, {
    set(callback, delay) { timers.set(++id, {callback, delay}); return id },
    clear(id) { const t = timers.get(id); if (t) cancelled.push(t.callback); timers.delete(id) }
  })
  return { c, timers, cancelled, calls: () => calls,
    fire() { const [id, t] = [...timers][0]; timers.delete(id); t.callback() } }
}
test('only complete expected original display parts start one full one-shot interval', () => {
  const f = fixture(), s = snapshot(); f.c.setEnabled(true)
  for (const change of [s => s.frames = [], s => s.frames.pop(), s => s.frames[0].asset.phase = 'decoding',
    s => s.frames[0].asset.kind = 'thumbnail', s => s.frames[0].asset.page.key = 'wrong',
    s => s.frames[0] = s.frames[1], s => s.pageMetadata = []]) {
    const bad = snapshot(); change(bad); f.c.update(bad, true, false); assert.equal(f.timers.size, 0)
  }
  f.c.update(s, true, false); assert.equal([...f.timers.values()][0].delay, 3000)
  f.c.update(s, true, false); assert.equal(f.timers.size, 1)
  f.fire(); assert.equal(f.calls(), 1); f.c.update(s, true, false); assert.equal(f.timers.size, 0)
})
test('manual navigation, resource replacement and topology restart; late callbacks cannot advance', () => {
  const f = fixture(); f.c.update(snapshot(), true, false); f.c.setEnabled(true)
  for (const change of [s => s.navigationRevision++, s => s.frames[0].asset.assetRequestId += 10,
    s => s.policy.direction = 'ltr', s => s.topologyRevision++]) {
    const s = snapshot(); change(s); f.c.update(s, true, false)
    assert.equal(f.timers.size, 1); assert.equal(f.c.isEnabled(), true)
    for (const late of f.cancelled) late(); assert.equal(f.calls(), 0)
  }
  f.fire(); assert.equal(f.calls(), 1)
})
test('foreground and blocking pause then restart a full interval; failures await retry', () => {
  const f = fixture(), s = snapshot(); f.c.update(s, true, false, 7); f.c.setEnabled(true)
  for (const [foreground, blocked] of [[false, false], [true, true]]) {
    f.c.update(s, foreground, blocked, 7); assert.equal(f.timers.size, 0)
    f.c.update(s, true, false, 7); assert.equal([...f.timers.values()][0].delay, 7000)
  }
  s.frames[0].asset.phase = 'failed'; f.c.update(s, true, false, 7); assert.equal(f.timers.size, 0)
  assert.equal(f.c.isEnabled(), true); s.frames[0].asset.phase = 'displayed'; f.c.update(s, true, false, 7)
  assert.equal([...f.timers.values()][0].delay, 7000)
})
test('continuous index change without navigation restarts; anchor movement alone does not', () => {
  const f = fixture(), s = snapshot(0, 'continuous'); f.c.update(s, true, false); f.c.setEnabled(true)
  const timer = [...f.timers.keys()][0]; s.anchor = {y: .5}; f.c.update(s, true, false)
  assert.equal([...f.timers.keys()][0], timer)
  f.c.update(snapshot(1, 'continuous'), true, false); assert.notEqual([...f.timers.keys()][0], timer)
  f.cancelled[0](); assert.equal(f.calls(), 0); f.fire(); assert.equal(f.calls(), 1)
})
test('last display stops only after ready full interval and never crosses unit', () => {
  const f = fixture(), s = snapshot(2, 'spread', 5); s.frames[0].asset.phase = 'failed'
  f.c.update(s, true, false); f.c.setEnabled(true); assert.equal(f.c.isEnabled(), true); assert.equal(f.timers.size, 0)
  s.frames[0].asset.phase = 'displayed'; f.c.update(s, true, false); assert.equal(f.timers.size, 1)
  f.fire(); assert.equal(f.c.isEnabled(), false); assert.equal(f.calls(), 0)
})
test('unit and layout changes stop; stop and close fence all late timers', () => {
  for (const mode of ['unit', 'layout', 'stop', 'close']) {
    const f = fixture(); f.c.update(snapshot(), true, false); f.c.setEnabled(true)
    if (mode === 'stop') f.c.stop()
    else if (mode === 'close') f.c.close()
    else { const s = snapshot(); if (mode === 'unit') s.unit.key.work = 'other'; else s.policy.layout = 'single'; f.c.update(s, true, false) }
    assert.equal(f.c.isEnabled(), false); assert.equal(f.timers.size, 0)
    f.cancelled.forEach(cb => cb()); assert.equal(f.calls(), 0)
    if (mode === 'close') { f.c.setEnabled(true); f.c.update(snapshot(), true, false); assert.equal(f.timers.size, 0) }
  }
})
test('host interval rounds and clamps finite values to 1–60; nonfinite values use 3', () => {
  const f = fixture(); f.c.setEnabled(true)
  for (const value of [1, 60, 0, 61, 1.5, 1.4, -10, NaN, Infinity]) {
    f.c.update(snapshot(), true, false, value)
    assert.equal([...f.timers.values()][0].delay, (Number.isFinite(value) ? Math.max(1, Math.min(60, Math.round(value))) : 3) * 1000)
  }
})
test('cover-alone is complete with one expected part; next callback may synchronously update selection', () => {
  const s = snapshot(0, 'single'); s.policy.layout = 'spread'; s.policy.firstPageAlone = true
  s.displayCount = new ReaderDisplayMap(s.unit, s.pageMetadata, s.policy).count()
  const timers = new Map(); let id = 0, calls = 0, c
  c = new ReaderAutoReadController(() => { calls++; c.update(snapshot(1), true, false); return true }, {
    set(cb, delay) { timers.set(++id, cb); return id }, clear(id) { timers.delete(id) }
  })
  c.update(s, true, false); c.setEnabled(true); assert.equal(timers.size, 1)
  const old = timers.get(1); timers.delete(1); old()
  assert.equal(calls, 1); assert.equal(timers.size, 1); old(); assert.equal(calls, 1)
})
test('rejected next retries only after a full interval, then accepted next is consumed', () => {
  const timers = new Map(); let id = 0, calls = 0, accepted = false
  const c = new ReaderAutoReadController(() => { calls++; return accepted }, {
    set(cb, delay) { timers.set(++id, {cb, delay}); return id }, clear(id) { timers.delete(id) }
  })
  c.update(snapshot(), true, false, 5); c.setEnabled(true)
  const first = timers.get(1); timers.delete(1); first.cb()
  assert.equal(calls, 1); assert.equal(timers.size, 1); assert.equal(timers.get(2).delay, 5000)
  first.cb(); assert.equal(calls, 1)
  accepted = true; const second = timers.get(2); timers.delete(2); second.cb()
  c.update(snapshot(), true, false, 5); assert.equal(calls, 2); assert.equal(timers.size, 0)
})
test('rejected callback with synchronous new-identity update preserves its single timer', () => {
  const timers = new Map(); let id = 0, calls = 0, c
  c = new ReaderAutoReadController(() => { calls++; c.update(snapshot(1), true, false, 8); return false }, {
    set(cb, delay) { timers.set(++id, {cb, delay}); return id }, clear(id) { timers.delete(id) }
  })
  c.update(snapshot(), true, false); c.setEnabled(true)
  const first = timers.get(1); timers.delete(1); first.cb()
  assert.equal(calls, 1); assert.equal(timers.size, 1); assert.equal(id, 2); assert.equal(timers.get(2).delay, 8000)
  first.cb(); assert.equal(calls, 1); assert.equal(timers.size, 1)
})
