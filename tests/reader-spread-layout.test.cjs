const test = require('node:test'), assert = require('node:assert/strict')
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load = require('./load-core.cjs')
const core = { ...load('ReaderContent'), ...load('ReaderSession'), ...load('ReaderDisplayMap'),
  ...load('ReaderPagedSession'), ...load('ReaderViewportTransform') }
// Execute the production numerical/interaction methods, not ArkUI builders or screenshot acceptance.
function subject(file, names, prelude = '') {
  const source = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets', file + '.ets'), 'utf8')
  const bodies = names.map(name => {
    const match = new RegExp('^  (?:private )?' + name + '\\(', 'm').exec(source)
    assert.ok(match, name)
    const start = match.index, brace = source.indexOf('{', start); let depth = 1, end = brace + 1
    for (; depth; end++) { if (source[end] === '{') depth++; else if (source[end] === '}') depth-- }
    return source.slice(start, end)
  })
  const context = { ...core, exports: {} }
  vm.runInNewContext(ts.transpileModule(prelude + '\nexport class Subject {' + bodies.join('\n') + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, context)
  return context.exports.Subject
}
const src = fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagedViewport.ets'), 'utf8')
const ratio = src.slice(src.indexOf('function partRatio('), src.indexOf('/** Entry eligibility'))
const Viewport = subject('ReaderPagedViewport', ['geometry', 'totalRatio', 'frameHeight', 'splitLayout', 'containedHeight', 'equalSlots'], ratio)
const Chrome = subject('ReaderChrome', ['toggleSpreadLayout'])
function frame(i, width, height) {
  const key = new core.ReaderUnitKey('test', 'work', 'unit')
  const page = new core.ReaderPage(key, `p${i}`, i); page.width = width; page.height = height
  const asset = new core.ReaderSnapshot(); asset.page = page; asset.kind = 'original'; asset.phase = 'displayed'
  return new core.ReaderPagedFrame(i + 1, new core.ReaderDisplayPart(key, page.key, i), asset)
}
function viewport(layout = 'split') {
  const snapshot = new core.ReaderPagedSnapshot(); snapshot.policy.layout = 'spread'; snapshot.policy.spreadLayout = layout
  snapshot.frames = [frame(0, 100, 1000), frame(1, 2000, 1000)]
  return Object.assign(new Viewport(), { snapshot, viewportWidth: 1200, viewportHeight: 800, recovering: false })
}
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-8, `${a} != ${b}`)

test('split equal slots contain unequal pages and both actual outer edges remain reachable', () => {
  const v = viewport(), g = v.geometry()
  assert.equal(v.equalSlots(), true)
  near(v.containedHeight(v.snapshot.frames[0]), 800)
  near(v.containedHeight(v.snapshot.frames[1]), 300)
  near(g.contentWidth, 940); near(g.contentCenterX, 130)
  near(g.contentHeight, 800); near(g.nativeScale, 1000 / 300)
  const pan = new core.ReaderViewportTransform(2).pan(g, 10000, 10000)
  near(pan.x, 80); near(pan.y, 400)
  near(new core.ReaderViewportTransform(2).pan(g, -10000, 0).x, -600)
})

test('joined retains proportional equal-height fit and terminal singleton uses full single fit', () => {
  const v = viewport('joined'), g = v.geometry()
  near(g.contentWidth, 1200); near(g.contentHeight, 1200 / 2.1)
  assert.equal(v.equalSlots(), false)
  v.snapshot.policy.spreadLayout = 'split'; v.snapshot.frames = [v.snapshot.frames[1]]
  assert.equal(v.splitLayout(), false); near(v.geometry().contentWidth, 1200); near(v.geometry().contentHeight, 600)
  v.snapshot.policy.layout = 'single'; near(v.geometry().contentHeight, 600)
})

test('crop ratio and intrinsic height drive split contain/native bounds and clamp existing zoom', () => {
  const v = viewport()
  v.snapshot.frames[1].crop.region = () => ({ width: 0.25, height: 0.5 })
  const g = v.geometry()
  near(v.containedHeight(v.snapshot.frames[1]), 600)
  near(g.contentWidth, 940); near(g.contentCenterX, 130); near(g.contentHeight, 800); near(g.nativeScale, 1.25)
  const zoom = new core.ReaderViewportTransform(2, 999, -999).constrained(g)
  near(zoom.x, 80); near(zoom.y, -400)
})

test('narrow strip split regression includes slot gap and asymmetric edges at 2x', () => {
  const v = viewport()
  v.viewportWidth = 1260; v.viewportHeight = 2596
  v.snapshot.frames = [frame(0, 212, 2596), frame(1, 196, 2596)]
  const g = v.geometry()
  near(g.contentWidth, 834); near(g.contentCenterX, -4)
  const right = new core.ReaderViewportTransform(2).pan(g, 10000, 0)
  const left = new core.ReaderViewportTransform(2).pan(g, -10000, 0)
  near(right.x, 212); near(left.x, -196)
  near(2 * (g.contentCenterX - g.contentWidth / 2) + right.x, -g.width / 2)
  near(2 * (g.contentCenterX + g.contentWidth / 2) + left.x, g.width / 2)
  const fit = new core.ReaderViewportTransform(1, 999, -999).constrained(g)
  near(fit.x, 0); near(fit.y, 0)
})

test('recovery slots persist until recovery ends without changing stored joined geometry', () => {
  const v = viewport('joined'), before = v.geometry()
  v.recovering = true; assert.equal(v.equalSlots(), true)
  near(v.geometry().contentWidth, before.contentWidth)
  v.recovering = false; assert.equal(v.equalSlots(), false)
  v.snapshot.policy.spreadLayout = 'split'; assert.equal(v.equalSlots(), true)
})

test('spread menu copies policy without changing direction, axis, grouping options or nonspread state', () => {
  const v = viewport('joined'), calls = [], chrome = new Chrome()
  Object.assign(chrome, { snapshot: v.snapshot, onPolicy: p => calls.push(p) })
  v.snapshot.policy.direction = 'rtl'; v.snapshot.policy.pagingAxis = 'vertical'; v.snapshot.policy.firstPageAlone = true
  chrome.toggleSpreadLayout()
  assert.equal(calls[0].spreadLayout, 'split'); assert.equal(v.snapshot.policy.spreadLayout, 'joined')
  assert.equal(calls[0].direction, 'rtl'); assert.equal(calls[0].pagingAxis, 'vertical'); assert.equal(calls[0].firstPageAlone, true)
  v.snapshot.policy = calls[0]; chrome.toggleSpreadLayout(); assert.equal(calls[1].spreadLayout, 'joined')
  v.snapshot.policy.layout = 'continuous'; chrome.toggleSpreadLayout(); assert.equal(calls.length, 2)
})
