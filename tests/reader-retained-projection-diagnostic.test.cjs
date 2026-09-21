const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const ts = require(process.env.READER_KIT_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')

const root = path.join(__dirname, '../reader-ui/src/main/ets')
const read = name => fs.readFileSync(path.join(root, name), 'utf8')
const viewport = read('ReaderPagedViewport.ets')
const core = name => fs.readFileSync(path.join(__dirname, '../reader-core/src/main/ets', name), 'utf8')
const nextN = name => fs.readFileSync(path.join(__dirname, '../../..', name), 'utf8')

function cellMethod(name) {
  const tree = ts.createSourceFile('ReaderPagedViewport.ets',
    viewport.replace('struct ReaderPagedCell', 'class ReaderPagedCell'), ts.ScriptTarget.Latest, true)
  const cell = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderPagedCell')
  const member = cell.members.find(value => value.name?.getText(tree) === name)
  assert.ok(member, name)
  const out = {}
  const events = []
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${member.getText(tree)} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out, console: { info(message) { events.push(message) } } })
  return { Subject: out.Subject, events }
}

function surfaceMethod(name) {
  const source = read('ReaderSurface.ets')
  const tree = ts.createSourceFile('ReaderSurface.ets',
    source.replace('export struct ReaderSurface', 'class ReaderSurface'), ts.ScriptTarget.Latest, true)
  const surface = tree.statements.find(value => ts.isClassDeclaration(value) && value.name?.getText(tree) === 'ReaderSurface')
  const member = surface.members.find(value => value.name?.getText(tree) === name)
  assert.ok(member, name)
  const out = {}
  vm.runInNewContext(ts.transpileModule(`export class Subject { ${member.getText(tree)} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  }).outputText, { exports: out })
  return out.Subject
}

test('restricted diagnostic reports the local retained projection and actual spinner predicate', () => {
  const { Subject, events } = cellMethod('reportRetainedProjection')
  const subject = new Subject()
  const frame = {
    slotId: 1,
    part: { sourceIndex: 2 },
    asset: { phase: 'decoding', assetRequestId: 4, retainedUri: 'file://retained', retainedAssetRequestId: 3 },
  }
  Object.assign(subject, {
    retainedProjectionDiagnostic: true,
    lastRetainedProjectionDiagnostic: '',
    snapshot: { selectionId: 7, navigationRevision: 9 },
    retainedFrameValue: null,
    frame: () => frame,
  })
  subject.reportRetainedProjection()
  subject.reportRetainedProjection()
  subject.retainedFrameValue = { asset: { assetRequestId: 3, uri: 'file://retained' } }
  subject.reportRetainedProjection()
  assert.equal(events.length, 2, 'identical state does not flood hilog')
  assert.match(events[0], /source=2 slot=1 asset_phase=decoding asset_request=4 .*raw_retained_uri_length=15 raw_retained_request=3 local_retained=false local_request=0 local_uri_length=0 spinner=true/)
  assert.match(events[1], /local_retained=true local_request=3 local_uri_length=15 spinner=false/)
})

test('variant policy does not start a second replacement while the retained fallback owns the frame', async () => {
  const Subject = surfaceMethod('syncPreferredVariant')
  const calls = []
  const preference = { variant: 'enhanced', identity: 'model-a' }
  const frame = {
    slotId: 1,
    part: { sourceIndex: 2 },
    asset: { phase: 'displayed', variant: 'default', variantIdentity: '', requestId: 8, assetRequestId: 7 },
  }
  const subject = new Subject()
  Object.assign(subject, {
    active: true,
    closing: false,
    chromeDisposed: false,
    variantAttemptContext: '',
    variantAttempts: new Set(),
    variantPolicy: {
      defaultPreference: () => preference,
      hasPerSourcePreference: () => false,
      preference: () => preference,
      revision: 1,
      selectionCompleted: (_source, _preference, result) => calls.push(`result:${result}`),
    },
    session: {
      selectVariant: (...args) => { calls.push(args); return Promise.resolve('changed') },
    },
    reconcileTemporaryVariantOverride: () => null,
    temporaryVariantOverride: { clear(){}, reconcile(){}, isDisabled: () => false, toggle: () => false, revision: 0, preference: (_scope, _source, _key, resolved) => resolved },
  })
  const state = {
    phase: 'ready',
    kind: 'original',
    navigationRevision: 3,
    unit: { key: { scope: 's', work: 'w', unit: 'u', copy: () => ({}) } },
    frames: [frame],
  }
  subject.syncPreferredVariant(state)
  assert.equal(calls.length, 0, 'the old visible asset is already being replaced')
  frame.asset.requestId = 7
  subject.syncPreferredVariant(state)
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(calls[0].slice(0, 3), [1, 7, {}])
  assert.equal(calls.at(-1), 'result:changed')
})

test('diagnostic wiring is default-off and reaches the exact paged cell and session decision', () => {
  const surface = read('ReaderSurface.ets')
  const pager = read('ReaderPagerSurface.ets')
  const session = core('ReaderSession.ets')
  const paged = core('ReaderPagedSession.ets')
  const lab = nextN('feature/reader/src/main/ets/lab/NextNReaderLabPage.ets')
  assert.match(surface, /@Param retainedProjectionDiagnostic: boolean = false/)
  assert.match(surface, /if \(frame\.asset\.requestId !== frame\.asset\.assetRequestId\) \{[\s\S]*?cancelRetainedProcessedVariantReplacements\(\[frame\.part\.sourceIndex\]\)/)
  assert.match(surface, /ReaderPagerSurface\(\{[\s\S]*retainedProjectionDiagnostic: this\.retainedProjectionDiagnostic/)
  assert.match(pager, /export struct ReaderPagerSurface \{[\s\S]*@Param retainedProjectionDiagnostic: boolean = false/)
  assert.match(pager, /struct ReaderNativePager \{[\s\S]*@Param retainedProjectionDiagnostic: boolean = false/)
  assert.match(pager, /ReaderPagedViewport\(\{[\s\S]*retainedProjectionDiagnostic: this\.retainedProjectionDiagnostic/)
  assert.match(viewport, /export struct ReaderPagedViewport \{[\s\S]*@Param retainedProjectionDiagnostic: boolean = false/)
  assert.match(viewport, /ReaderPagedCell\(\{[\s\S]*retainedProjectionDiagnostic: this\.retainedProjectionDiagnostic/)
  assert.match(viewport, /struct ReaderPagedCell \{[\s\S]*@Param retainedProjectionDiagnostic: boolean = false/)
  assert.match(viewport, /private syncRetainedFrame\(\): void \{[\s\S]*this\.reportRetainedProjection\(\)/)
  assert.match(session, /private retainedDecisionDiagnostic: boolean = false/)
  assert.match(session, /setRetainedDecisionDiagnostic\(enabled: boolean\): void \{ this\.retainedDecisionDiagnostic = enabled \}/)
  assert.match(session, /\[ReaderSession\] retained_decision[\s\S]*replacing_variant=\$\{isReplacingVariant\}[\s\S]*retain_displayed=\$\{retainDisplayed\}/)
  assert.match(paged, /setRetainedDecisionDiagnostic\(enabled: boolean\): void \{[\s\S]*slot\.session\.setRetainedDecisionDiagnostic\(enabled\)/)
  assert.match(paged, /new ReaderSession\(this\.catalog, this\.assets, this\.failures\)[\s\S]*session\.setRetainedDecisionDiagnostic\(this\.retainedDecisionDiagnostic\)/)
  assert.match(lab, /superResolutionRehearsalDiagnostic = superResolutionRecording[\s\S]*session\.setRetainedDecisionDiagnostic\(superResolutionRecording\)/)
})
