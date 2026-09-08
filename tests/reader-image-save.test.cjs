const test = require('node:test')
const assert = require('node:assert/strict')
const load = require('./load-core.cjs')
const { ReaderImageSaveTarget: Target, ReaderImageSaveController: Controller } = load('ReaderImageSave')
const { ReaderUnit, ReaderUnitKey, ReaderPage } = load('ReaderContent')
const { ReaderSnapshot } = load('ReaderSession')
const { ReaderPagedSnapshot, ReaderPagedFrame } = load('ReaderPagedSession')
const { ReaderReadingAnchor, ReaderDisplayPart } = load('ReaderDisplayMap')
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b }); return {promise,resolve,reject} }
function snapshot() {
  const s = new ReaderPagedSnapshot()
  s.unit = new ReaderUnit(new ReaderUnitKey('s','w','u'), 'Title', 10)
  s.phase='ready'; s.policy.layout='spread'; s.policy.direction='rtl'; s.navigationRevision=3
  s.anchor=new ReaderReadingAnchor(s.unit.key,'p0',0)
  s.frames=[1,0].map(i => {
    const a=new ReaderSnapshot(); a.unit=s.unit.copy(); a.page=new ReaderPage(s.unit.key,`p${i}`,i)
    a.sourceIndex=i; a.phase='displayed'; a.uri=`file://${i}`; a.assetRequestId=i+1
    return new ReaderPagedFrame(i+1,new ReaderDisplayPart(s.unit.key,`p${i}`,i,'whole'),a)
  })
  return s
}
function ready() { const c=new Controller(); c.update(snapshot(),true); return c }
test('visual RTL targets, current anchor, copies, and displayed original gates', () => {
  const s=snapshot()
  assert.deepEqual(Target.from(s,'both').items.map(i=>i.sourceIndex),[1,0])
  assert.equal(Target.from(s,'left').items[0].sourceIndex,1)
  assert.equal(Target.from(s,'right').items[0].sourceIndex,0)
  assert.equal(Target.from(s,'current').items[0].sourceIndex,0)
  const t=Target.from(s,'both'); s.frames[0].asset.uri='changed'; assert.equal(t.items[0].uri,'file://1')
  for(const alter of [s=>s.frames[0].asset.phase='decoding',s=>s.frames[0].asset.kind='thumbnail',s=>s.frames[0].asset.uri='',s=>s.frames[0].asset.page.key='wrong',s=>s.frames[0].asset.page.sourceIndex=8]) {
    const s=snapshot(); alter(s); assert.equal(Target.from(s,'both'),null)
  }
})
test('late prepare releases once, never presents, and cannot clear newer busy operation', async () => {
  const c=ready(), a=deferred(), b=deferred(); let released=0, shown=0
  const old=c.save({prepare:()=>a.promise},'both')
  const s=snapshot(); s.frames[0].asset.assetRequestId=20; c.update(s,true)
  const fresh=c.save({prepare:()=>b.promise},'both')
  a.resolve({present:async()=>{shown++},release:()=>released++})
  assert.equal((await old).outcome,'cancelled'); assert.equal(shown,0); assert.equal(released,1); assert.equal(c.busy(),true)
  b.resolve({present:async()=>[],release:()=>released++}); await fresh
  assert.equal(released,2); assert.equal(c.busy(),false)
})
test('foreground loss and close after presentation preserve partial results and resource lifetime', async () => {
  const c=ready(), done=deferred(); let released=0; const events=[]; c.subscribe(v=>events.push(v))
  const run=c.save({prepare:async()=>({present:()=>{c.update(snapshot(),false);return done.promise},release:()=>{released++;throw Error('cleanup')}})},'both')
  await Promise.resolve(); assert.equal(c.busy(),true); assert.equal(released,0)
  assert.equal((await c.save({},'both')).outcome,'ignored'); c.close(); assert.equal(released,0)
  done.resolve([{sourceIndex:1,status:'saved'},{sourceIndex:0,status:'failed'}])
  const result=await run; assert.equal(result.outcome,'completed'); assert.deepEqual(result.items.map(i=>i.status),['saved','failed'])
  assert.equal(released,1); assert.deepEqual(events,[false,true])
})
test('deactivation irreversibly cancels prepare even if same page resumes', async () => {
  const c=ready(), d=deferred(); let token, released=0
  const run=c.save({prepare:(_,t)=>{token=t;return d.promise}},'current')
  c.update(snapshot(),false); c.update(snapshot(),true); assert.equal(token.isCancelled(),true)
  d.resolve({present:()=>{throw Error('must not present')},release:()=>released++})
  assert.equal((await run).outcome,'cancelled'); assert.equal(released,1)
})
test('presentation exceptions remain failed after foreground loss; prepare exceptions respect cancellation', async () => {
  const c=ready(); assert.equal((await c.save({prepare:async()=>{throw Error('prepare')}},'current')).outcome,'failed')
  let released=0
  assert.equal((await c.save({prepare:async()=>({present:async()=>{c.update(snapshot(),false);throw Error('copy')},release:()=>released++})},'current')).outcome,'failed')
  assert.equal(released,1)
})
test('host cancellation remains an actual per-page result, and duplicates do not prepare', async () => {
  const c=ready(), d=deferred(); let calls=0
  const host={prepare:async()=>{calls++;return {present:()=>d.promise,release:()=>{}}}}
  const run=c.save(host,'both'); await Promise.resolve()
  assert.equal((await c.save(host,'both')).outcome,'ignored'); assert.equal(calls,1)
  d.resolve([{sourceIndex:1,status:'cancelled'},{sourceIndex:0,status:'cancelled'}])
  assert.deepEqual((await run).items.map(i=>i.status),['cancelled','cancelled'])
})
test('captured snapshot and target isolate caller mutation; closed prepare cannot present', async () => {
  const c=new Controller(), s=snapshot(), d=deferred(); c.update(s,true)
  s.frames[0].asset.uri='mutated'
  let captured, released=0
  const run=c.save({prepare:(target)=>{captured=target;return d.promise}},'right')
  assert.equal(captured.items[0].uri,'file://0')
  c.close()
  d.resolve({present:()=>{throw Error('late')},release:()=>released++})
  assert.equal((await run).outcome,'cancelled'); assert.equal(released,1)
  assert.equal((await c.save({},'current')).outcome,'ignored')
})
test('LTR visual order and changed navigation reject old target equality', () => {
  const s=snapshot(); s.policy.direction='ltr'; s.frames.reverse()
  const t=Target.from(s,'both')
  assert.deepEqual(t.items.map(i=>i.sourceIndex),[0,1])
  assert.equal(t.equals(t.copy()),true)
  s.navigationRevision++; assert.equal(t.equals(Target.from(s,'both')),false)
  s.policy.layout='single'; assert.equal(Target.from(s,'left'),null)
})
test('real paged session supplies visual RTL order and full resource for physical halves', async () => {
  const { ReaderPagedSession }=load('ReaderPagedSession')
  const { ReaderAsset }=load('ReaderSession')
  const { ReaderDisplayPolicy }=load('ReaderDisplayMap')
  const key=new ReaderUnitKey('s','w','u')
  const catalog={open:async k=>new ReaderUnit(k,'Title',4),page:async (u,i)=>{
    const p=new ReaderPage(u.key,`p${i}`,i);p.width=1800;p.height=1200;return p
  },adjacent:()=>null}
  const assets={cancellationMode:'consumer-only',load:async p=>new ReaderAsset(`file://whole-${p.sourceIndex}`)}
  const session=new ReaderPagedSession(catalog,assets)
  const policy=new ReaderDisplayPolicy();policy.layout='spread';policy.direction='rtl'
  session.setPolicy(policy);session.setViewportActive(true)
  await session.open(key);await new Promise(r=>setImmediate(r))
  for(const f of session.snapshot().frames)session.reportPresentation(f.slotId,f.asset.assetRequestId,true)
  const s=session.snapshot()
  assert.deepEqual(s.frames.map(f=>f.part.sourceIndex),[1,0])
  assert.equal(Target.from(s,'left').items[0].sourceIndex,1)
  assert.equal(Target.from(s,'right').items[0].sourceIndex,0)
  assert.deepEqual(Target.from(s,'both').items.map(i=>[i.pageKey,i.uri]),[['p1','file://whole-1'],['p0','file://whole-0']])
  policy.layout='single';policy.splitWidePages=true;session.setPolicy(policy)
  await new Promise(r=>setImmediate(r))
  for(const f of session.snapshot().frames)session.reportPresentation(f.slotId,f.asset.assetRequestId,true)
  const first=Target.from(session.snapshot(),'current')
  assert.equal(session.snapshot().frames[0].part.fragment,'right')
  session.move('next');await new Promise(r=>setImmediate(r))
  assert.equal(session.snapshot().frames[0].part.fragment,'left')
  const second=Target.from(session.snapshot(),'current')
  assert.equal(first.items[0].uri,'file://whole-0');assert.equal(second.items[0].uri,first.items[0].uri)
  assert.equal(second.items[0].pageKey,first.items[0].pageKey)
  assert.equal(Target.from(session.snapshot(),'both'),null)
  session.close()
})
