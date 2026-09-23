const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const pager = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagerSurface.ets'), 'utf8')
const surface = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')

test('one-shot pager command waits for native selection before mutating the session', () => {
  const requestMove = surface.slice(surface.indexOf('  private requestMove('), surface.indexOf('  private reportInputLock('))
  assert.match(surface, /this\.pagerCommand = new ReaderPagerCommand\(/)
  assert.ok(requestMove.indexOf('this.pagerCommand = new ReaderPagerCommand(') < requestMove.indexOf('this.session.move(intent)'))
  assert.match(requestMove, /this\.pagerCommand = new ReaderPagerCommand\([\s\S]+?return true[\s\S]+?this\.session\.move\(intent\)/)
  assert.match(pager, /Swiper\(this\.controller\)/)
  assert.match(pager, /this\.controller\.changeIndex\(command\.targetIndex, command\.animated\)/)
  assert.match(pager, /onSelect\(index, this\.createdRevision, navigation\)/)
})

test('native command is fenced by serial, topology, navigation, bounds and input state', () => {
  assert.match(pager, /command\.serial <= this\.lastCommandSerial/)
  assert.match(pager, /!this\.active \|\| this\.inputLocked \|\| \(command\.animated && this\.moving\)/)
  assert.match(pager, /command\.topologyRevision !== this\.createdRevision/)
  assert.match(pager, /command\.topologyRevision !== this\.snapshot\.topologyRevision/)
  assert.match(pager, /command\.navigationRevision !== this\.snapshot\.navigationRevision/)
  assert.match(pager, /command\.targetIndex < 0 \|\| command\.targetIndex >= this\.snapshot\.displayCount/)
})

test('late OFF callbacks cannot commit the first of two native commands', () => {
  const method = (start, end) => {
    const from = pager.indexOf(start)
    return pager.slice(from, pager.indexOf(end, from + start.length))
  }
  const code = `class Harness {
    ${method('  onCommandChanged(): void {', '  private beginMotion(): void {')}
    ${method('  private beginMotion(): void {', '  private queueSelection(index: number): void {')}
    ${method('  private queueSelection(index: number): void {', '  build() {')}
  }
  exports.Harness = Harness`
  const timers = new Map()
  const frames = []
  let nextTimer = 0
  const exports = {}
  vm.runInNewContext(ts.transpileModule(code, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, {
    exports, console: { info() {}, warn() {} },
    setTimeout(callback) { const id = ++nextTimer; timers.set(id, callback); return id },
    clearTimeout(id) { timers.delete(id) },
    ReaderPagerAfterFrame: class ReaderPagerAfterFrame { constructor(callback) { this.action = callback } },
    ReaderPositionHandoff: class ReaderPositionHandoff {
      constructor(serial, targetIndex, topologyRevision, navigationRevision, snapshot, prior) {
        Object.assign(this, { serial, targetIndex, topologyRevision, navigationRevision,
          targetKey: snapshot.displayKeys[targetIndex], oldKey: prior?.oldKey ?? snapshot.displayKeys[snapshot.displayIndex],
          oldProjection: prior?.oldProjection ?? snapshot.forItem(snapshot.displayKeys[snapshot.displayIndex]) })
      }
      current(serial, snapshot) { return this.serial === serial &&
        this.topologyRevision === snapshot.topologyRevision && this.targetKey === snapshot.displayKeys[this.targetIndex] }
    },
  })
  const native = new exports.Harness()
  const selected = []
  const changed = []
  Object.assign(native, {
    active: true, inputLocked: false, moving: false, createdRevision: 7,
    snapshot: { topologyRevision: 7, navigationRevision: 10, displayCount: 3, displayIndex: 0,
      displayKeys: ['a', 'b', 'c'], forItem(key) { return { key } } },
    lastCommandSerial: 0, commandTarget: -1, commandNavigation: -1,
    pendingChange: 0, gestureNavigation: -1,
    controller: { changeIndex(index, animated) { changed.push([index, animated]) } },
    getUIContext() { return { postFrameCallback(callback) { frames.push(callback.action) } } },
    onSelect(index, topology, navigation) { selected.push([index, topology, navigation]) },
  })
  const command = (serial, targetIndex) => ({ serial, targetIndex, topologyRevision: 7,
    navigationRevision: 10, animated: false })
  native.command = command(1, 1); native.onCommandChanged()
  native.oldVisualMounted = true; native.startOffCommandAfterFrame(native.command); frames.shift()()
  native.queueSelection(1)
  const staleCallback = timers.get(native.pendingChange)
  native.command = command(2, 2); native.onCommandChanged(); frames.shift()()
  staleCallback() // A callback already dequeued by the runtime can beat clearTimeout.
  native.queueSelection(1) // The first native onChange may also arrive after command 2.
  native.queueSelection(2)
  timers.get(native.pendingChange)()
  assert.deepEqual(changed, [[1, false], [2, false]])
  assert.deepEqual(selected, [[2, 7, 10]])

  // A later request back to the still-current logical page fences the old target,
  // even when Swiper emits no onChange for the already-current .index(0).
  native.command = command(3, 1); native.onCommandChanged(); frames.shift()()
  native.command = command(4, 0); native.onCommandChanged(); frames.shift()()
  native.queueSelection(1)
  assert.deepEqual(selected, [[2, 7, 10]])
  assert.equal(native.positionHandoff.serial, 4)
  frames.shift()() // No native onChange is required when returning to the logical old item.
  assert.equal(native.positionHandoff, null)
  assert.equal(native.commandTarget, -1)
})

// 2026-09-22 defect #4: both legacy readers commit an arbitrary seek target through the
// animated pager (NextE jumpToPage -> animateReaderPagerToIndex -> changeIndex(target, true)),
// so a chrome seek must not be limited to an adjacent step: an adjacency guard silently
// drops every non-adjacent thumbnail/slider jump instead of animating it.
test('chrome seeks animate arbitrary deltas instead of being dropped by an adjacency guard', () => {
  const seekWithPager = surface.slice(surface.indexOf('  private seekWithPager('),
    surface.indexOf('  private requestMove('))
  assert.match(seekWithPager, /session\.displayIndexForSource\(index\)/)
  assert.match(seekWithPager, /before\.navigationRevision !== navigation \|\| before\.unit\?\.key\.equals\(unit\) !== true/)
  assert.ok(!/Math\.abs\(target - /.test(seekWithPager), 'a chrome seek must not be adjacency-limited')
  assert.match(pager, /this\.controller\.changeIndex\(command\.targetIndex, command\.animated\)/)
  assert.ok(!/Math\.abs\(command\.targetIndex/.test(pager), 'the native owner must not drop non-adjacent commands')
})

test('paged moves use the same native owner with animation on or off; direct owners stay outside it', () => {
  assert.match(surface, /if \(before\.policy\.layout !== 'continuous' &&/)
  assert.match(surface, /const target = before\.displayIndex \+ \(intent === 'next' \? 1 : -1\)/)
  assert.match(pager, /if \(!command\.animated\) \{/)
  assert.match(pager, /this\.beginMotion\(\)/)
  assert.match(pager, /this\.controller\.changeIndex\(command\.targetIndex, command\.animated\)/)
  // The raw seek stays available as the fallback owner (continuous layout, unresolvable
  // target, or same-source re-seek), so it must remain reachable outside the command.
  assert.match(surface, /session\.seekSource\(index, unit, navigation\)/)
  assert.match(surface, /this\.session\.selectDisplay\(index, topology, navigation\)/)
})
