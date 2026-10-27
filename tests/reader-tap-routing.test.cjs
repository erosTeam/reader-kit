const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
function method(file, owner, name) {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets', file + '.ets'), 'utf8').replace(/\bstruct /g, 'class ')
  const tree = ts.createSourceFile('source.ts', source, ts.ScriptTarget.Latest, true)
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === owner)
  const member = cls.members.find(n => n.name?.getText(tree) === name).getText(tree)
  const exports = {}
  vm.runInNewContext(ts.transpileModule(`export class Host { ${member} }`, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, { exports })
  return new exports.Host()
}
function surface(layout = 'single', direction = 'ltr') {
  const host = method('ReaderSurface', 'ReaderSurface', 'pageTap'), moves = []
  Object.assign(host, { active: true, state: { phase: 'ready', topologyRevision: 2, policy: { layout, direction } },
    inputTopology: 2, previewIndex: -1, tapZoneResolver: null,
    session: { snapshot: () => ({ navigationRevision: 0 }), move: action => moves.push(action) },
    requestMove: action => { moves.push(action); return true }, toggleChrome: () => moves.push('menu') })
  return { host, moves }
}
test('real Surface preserves defaults and interprets physical directions once', () => {
  for (const direction of ['ltr', 'rtl']) for (const action of ['previous', 'next', 'left', 'right', 'menu', 'none']) {
    const { host, moves } = surface('single', direction)
    host.tapZoneResolver = (x, y, layout) => { assert.equal(x, .2); assert.equal(y, .8); assert.equal(layout, 'single'); return action }
    assert.equal(host.pageTap(.2, .8), action)
    const expected = action === 'left' ? (direction === 'ltr' ? 'previous' : 'next') :
      action === 'right' ? (direction === 'ltr' ? 'next' : 'previous') : action
    assert.deepEqual(moves, action === 'none' ? [] : [expected])
  }
  const f = surface(); f.host.pageTap(.1, .8); f.host.pageTap(.5, .8); f.host.pageTap(.9, .8)
  assert.deepEqual(f.moves, ['previous', 'menu', 'next'])
  const c = surface('continuous'); c.host.pageTap(.1, .8); assert.deepEqual(c.moves, ['menu'])
  c.host.tapZoneResolver = () => 'next'; c.host.pageTap(.1, .8); assert.deepEqual(c.moves, ['menu'])
})
test('paged taps at a chapter edge request the same direction as a boundary swipe', () => {
  for (const direction of ['ltr', 'rtl']) for (const action of ['previous', 'next', 'left', 'right']) {
    const f = surface('single', direction), boundaries = []
    f.host.state.displayIndex = 0
    f.host.state.navigationRevision = 3
    f.host.session.snapshot = () => ({ phase: 'ready', topologyRevision: 2, navigationRevision: 3,
      displayIndex: 0, displayCount: 1 })
    f.host.tapZoneResolver = () => action
    f.host.requestBoundaryChapter = (...args) => boundaries.push(args)
    f.host.pageTap(.2,.8)
    const expected = action === 'left' ? (direction === 'ltr' ? 'previous' : 'next') :
      action === 'right' ? (direction === 'ltr' ? 'next' : 'previous') : action
    assert.deepEqual(boundaries, [[expected,2,3]])
    assert.deepEqual(f.moves, [])
  }
})
test('real Surface rejects blocked input', () => {
  for (const field of ['closing', 'chromeDisposed', 'chromeCloseRequested', 'menuVisible', 'shareBusy', 'saveBusy', 'informationBusy']) {
    const f = surface(); f.host[field] = true; assert.equal(f.host.pageTap(.1, .2), 'none'); assert.deepEqual(f.moves, [])
  }
})
test('stable paged zoom preserves menu and existing navigation; resolver cannot move a retired session', () => {
  const f = surface(); f.host.inputLocked = true
  f.host.pageTap(.5, .5); f.host.pageTap(.1, .5)
  assert.deepEqual(f.moves, ['menu', 'previous'])
  for (const retire of [h => { h.closing = true }, h => { h.state.navigationRevision = 9 },
    h => { h.session.snapshot = () => ({ navigationRevision: 9 }) }]) {
    const g = surface(); g.host.tapZoneResolver = () => { retire(g.host); return 'next' }
    g.host.pageTap(.1, .2); assert.deepEqual(g.moves, [])
  }
})
function list() {
  const h = method('ReaderContinuousSurface', 'ReaderContinuousList', 'imageTap'), calls = [], scrolls = []
  Object.assign(h, { active: true, fullyVisible: true, lockedKey: '', createdRevision: 2,
    snapshot: { phase: 'ready', topologyRevision: 2, navigationRevision: 3, forItem: () => ({ frames: [{ asset: { phase: 'displayed' } }] }) },
    getUIContext: () => ({ px2vp: x => x / 2, getComponentUtils: () => ({ getRectangleById: () => ({ windowOffset: { x: 100, y: 200 }, size: { width: 800, height: 1200 } }) }) }),
    onTap: (x, y) => { calls.push([x, y]); return 'next' }, scroller: { scrollBy: (x, y) => scrolls.push([x, y]) } })
  return { h, calls, scrolls }
}
test('real List uses window viewport, not long image height, and scrolls 75 percent', () => {
  for (const action of ['next', 'right', 'previous', 'left', 'menu', 'none']) {
    const f = list(); f.h.onTap = (x, y) => { assert.equal(x, .25); assert.equal(y, .5); return action }
    f.h.imageTap('long-row', 150, 400)
    assert.deepEqual(f.scrolls, ['menu', 'none'].includes(action) ? [] : [[0, ['next', 'right'].includes(action) ? 450 : -450]])
  }
})
test('continuous taps cross only at the actual scroll edge', () => {
  for (const action of ['previous','left','next','right']) {
    const f=list(), boundaries=[]
    f.h.first=0; f.h.last=0; f.h.snapshot.displayCount=1
    f.h.scroller.currentOffset=()=>({yOffset:0})
    f.h.scroller.isAtEnd=()=>true
    f.h.onTap=()=>action
    f.h.onBoundary=(...args)=>boundaries.push(args)
    f.h.imageTap('row',150,400)
    const direction=['previous','left'].includes(action)?'previous':'next'
    assert.deepEqual(boundaries,[[direction,2,3]])
    assert.deepEqual(f.scrolls,[])
  }
})
test('real List rejects stale or locked geometry and callback navigation changes', () => {
  for (const field of ['disposed', 'pendingPosition', 'positionInFlight', 'moving']) {
    const f = list(); f.h[field] = true; f.h.imageTap('row', 150, 400); assert.deepEqual(f.calls, [])
  }
  const f = list(); f.h.onTap = () => { f.h.snapshot.navigationRevision++; return 'next' }
  f.h.imageTap('row', 150, 400); assert.deepEqual(f.scrolls, [])
  for (const coordinates of [[NaN, 400], [0, 0], [Infinity, 400]]) {
    const g = list(); g.h.imageTap('row', ...coordinates); assert.deepEqual(g.calls, [])
  }
})
test('stable continuous owner zoom permits menu resolution but no scrolling; nonfinite offset rejects', () => {
  const f = list(); f.h.lockedKey = 'row'
  f.h.imageTap('row', 150, 400)
  assert.equal(f.calls.length, 1); assert.deepEqual(f.scrolls, [])
  const g = list()
  g.h.getUIContext = () => ({ px2vp: x => x / 2, getComponentUtils: () => ({ getRectangleById: () => ({
    windowOffset: { x: NaN, y: 200 }, size: { width: 800, height: 1200 } }) }) })
  g.h.imageTap('row', 150, 400); assert.deepEqual(g.calls, [])
})


test('configurable double tap interval preserves immediate singles when zoom is disabled', () => {
  const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
  const ts = require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderTapArbiter.ets'), 'utf8')
  const exports = {}, timers = new Map(), events = []; let now = 0, serial = 0
  const Clock = class extends Date { static now() { return now } }
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2020 } }).outputText, { exports, Date: Clock,
    setTimeout: (action, delay) => { const id = ++serial; timers.set(id, { action, at: now + delay }); return id },
    clearTimeout: id => timers.delete(id) })
  const advance = ms => { now += ms; for (const [id, timer] of [...timers]) if (timer.at <= now) {
    timers.delete(id); timer.action()
  } }
  const arbiter = new exports.ReaderTapArbiter(point => events.push('single:' + point.x),
    point => events.push('double:' + point.x))
  const point = x => new exports.ReaderTapPoint(x, 0, x, 0)
  arbiter.tap(point(10), false, 300); assert.deepEqual(events, ['single:10']); assert.equal(timers.size, 0)
  arbiter.tap(point(20), true, 200); advance(199); assert.equal(events.length, 1)
  arbiter.down(21, 0); advance(100); arbiter.tap(point(21), true, 200)
  assert.deepEqual(events, ['single:10', 'double:21'])
  arbiter.tap(point(30), true, 200); advance(200)
  assert.deepEqual(events, ['single:10', 'double:21', 'single:30'])
  arbiter.tap(point(40), true, 200); arbiter.down(40, 0); arbiter.cancel(); advance(300)
  assert.equal(events.length, 3, 'a second gesture that becomes a drag must not turn the page')
})
