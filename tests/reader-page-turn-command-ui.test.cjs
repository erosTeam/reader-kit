const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const path = require('node:path')

const pager = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagerSurface.ets'), 'utf8')
const surface = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderSurface.ets'), 'utf8')

test('one-shot pager command waits for native selection before mutating the session', () => {
  const requestMove = surface.slice(surface.indexOf('  private requestMove('), surface.indexOf('  private reportInputLock('))
  assert.match(surface, /this\.pagerCommand = new ReaderPagerCommand\(/)
  assert.ok(requestMove.indexOf('this.pagerCommand = new ReaderPagerCommand(') < requestMove.indexOf('this.session.move(intent)'))
  assert.match(requestMove, /this\.pagerCommand = new ReaderPagerCommand\([\s\S]+?return true[\s\S]+?this\.session\.move\(intent\)/)
  assert.match(pager, /Swiper\(this\.controller\)/)
  assert.match(pager, /this\.controller\.changeIndex\(command\.targetIndex, true\)/)
  assert.match(pager, /onSelect\(index, this\.createdRevision, navigation\)/)
})

test('native command is fenced by serial, topology, navigation, bounds and input state', () => {
  assert.match(pager, /command\.serial <= this\.lastCommandSerial/)
  assert.match(pager, /!this\.active \|\| this\.inputLocked \|\| this\.moving/)
  assert.match(pager, /command\.topologyRevision !== this\.createdRevision/)
  assert.match(pager, /command\.topologyRevision !== this\.snapshot\.topologyRevision/)
  assert.match(pager, /command\.navigationRevision !== this\.snapshot\.navigationRevision/)
  assert.match(pager, /command\.targetIndex < 0 \|\| command\.targetIndex >= this\.snapshot\.displayCount/)
})

// 2026-09-22 defect #4: both legacy readers commit an arbitrary seek target through the
// animated pager (NextE jumpToPage -> animateReaderPagerToIndex -> changeIndex(target, true)),
// so a chrome seek must not be limited to an adjacent step: an adjacency guard silently
// drops every non-adjacent thumbnail/slider jump instead of animating it.
test('chrome seeks animate arbitrary deltas instead of being dropped by an adjacency guard', () => {
  const seekWithAnimation = surface.slice(surface.indexOf('  private seekWithAnimation('),
    surface.indexOf('  private requestMove('))
  assert.match(seekWithAnimation, /session\.displayIndexForSource\(index\)/)
  assert.match(seekWithAnimation, /if \(!this\.pageTurnAnimation\)/)
  assert.ok(!/Math\.abs\(target - /.test(seekWithAnimation), 'a chrome seek must not be adjacency-limited')
  assert.match(pager, /this\.controller\.changeIndex\(command\.targetIndex, true\)/)
  assert.ok(!/Math\.abs\(command\.targetIndex/.test(pager), 'the native owner must not drop non-adjacent commands')
})

test('only paged host moves use the command; direct navigation owners stay outside it', () => {
  assert.match(surface, /this\.pageTurnAnimation && before\.policy\.layout !== 'continuous'/)
  assert.match(surface, /const target = before\.displayIndex \+ \(intent === 'next' \? 1 : -1\)/)
  // The raw seek stays available as the fallback owner (continuous layout, unresolvable
  // target, or page-turn animation off), so it must remain reachable outside the command.
  assert.match(surface, /session\.seekSource\(index, unit, navigation\)/)
  assert.match(surface, /this\.session\.selectDisplay\(index, topology, navigation\)/)
})
