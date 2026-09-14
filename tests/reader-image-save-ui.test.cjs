const test=require('node:test'), assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const ts=require(process.env.READER_KIT_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const load=require('./load-core.cjs')
const core={...load('ReaderSession'),...load('ReaderDisplayMap'),...load('ReaderPagedSession'),...load('ReaderImageSave'),...load('ReaderImageShare'),...load('ReaderAutoRead')}
const closeExports={}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../reader-ui/src/main/ets/ReaderCloseContext.ets'),'utf8'),
  {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,
{exports:closeExports,require:name=>{assert.equal(name,'@reader-kit/core');return core}})
// Execute named real methods only; builders/decorators are not a simulated UI.
function methods(file,names) {
  const source=fs.readFileSync(path.join(__dirname,'../reader-ui/src/main/ets',file+'.ets'),'utf8')
  const bodies=names.map(name=>{
    const match=new RegExp('^  (?:private )?(?:async )?'+name+'\\(', 'm').exec(source)
    assert.ok(match,name)
    const start=match.index,brace=source.indexOf('{',start);let depth=1,end=brace+1
    for(;depth;end++){if(source[end]==='{')depth++;else if(source[end]==='}')depth--}
    return source.slice(start,end)
  })
  const context={...core,...closeExports,exports:{},$r:(...args)=>args.join(':'),console:{info(){}}}
  vm.runInNewContext(ts.transpileModule(`export class Subject {${bodies.join('\n')}}`,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,context)
  return context.exports.Subject
}
const Chrome=methods('ReaderChrome',['saveTarget','saveTargetsCurrent','openSave','selectSave','onSnapshotChanged','cancelSeek'])
const Surface=methods('ReaderSurface',['saveImage','flushSaveFeedback','shareImage','showInformation','aboutToDisappear','requestClose','onClosingChanged'])
const tick=()=>new Promise(r=>setImmediate(r))
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve}}
async function realSession() {
  const key=new core.ReaderUnitKey('s','w','u')
  const session=new core.ReaderPagedSession({open:async k=>new core.ReaderUnit(k,'Title',4),page:async(u,i)=>new core.ReaderPage(u.key,`p${i}`,i),adjacent:()=>null},
    {cancellationMode:'consumer-only',load:async p=>new core.ReaderAsset(`file://${p.sourceIndex}`)})
  const p=new core.ReaderDisplayPolicy();p.layout='spread';p.direction='rtl';session.setPolicy(p);session.setViewportActive(true)
  await session.open(key);await tick()
  for(const f of session.snapshot().frames)session.reportPresentation(f.slotId,f.asset.assetRequestId,true)
  return session
}
function chrome(snapshot) {
  const c=new Chrome(),selected=[]
  Object.assign(c,{snapshot,active:true,saveBusy:false,shareBusy:false,informationBusy:false,saveMenuShown:false,seekUnit:null,onSave:v=>selected.push(v)})
  return {c,selected}
}
test('real RTL snapshot opens visual P2/P1 menu and commits matching source selection',async()=>{
  const s=await realSession(),{c,selected}=chrome(s.snapshot())
  c.openSave();assert.equal(c.saveMenuShown,true);assert.equal(c.saveLeftIndex,1);assert.equal(c.saveRightIndex,0)
  assert.equal(c.saveLeft.items[0].sourceIndex,1);assert.equal(c.saveRight.items[0].sourceIndex,0)
  c.selectSave('left',c.saveLeft);assert.deepEqual(selected,['left']);s.close()
})
test('menu navigation/resource changes close and cannot commit captured choice',async()=>{
  for(const change of [s=>s.navigationRevision++,s=>s.frames[0].asset.assetRequestId++]) {
    const session=await realSession(),{c,selected}=chrome(session.snapshot());c.openSave();const captured=c.saveLeft
    change(c.snapshot);c.onSnapshotChanged();assert.equal(c.saveMenuShown,false)
    c.selectSave('left',captured);assert.deepEqual(selected,[]);session.close()
  }
})
test('failed neighbor retains P2 label but has no target; single page saves directly',async()=>{
  const s=await realSession(),state=s.snapshot();state.frames[0].asset.phase='failed'
  const {c,selected}=chrome(state);c.openSave()
  assert.equal(c.saveLeftIndex+1,2);assert.equal(c.saveLeft,null);assert.equal(c.saveBoth,null)
  assert.equal(c.saveRightIndex+1,1);assert.ok(c.saveRight)
  c.selectSave('left',c.saveLeft);assert.deepEqual(selected,[])
  const p=new core.ReaderDisplayPolicy();s.setPolicy(p);await tick();c.snapshot=s.snapshot();c.openSave()
  assert.deepEqual(selected,['current']);s.close()
})
function surface(session) {
  const s=new Surface(),toasts=[]
  Object.assign(s,{session,state:session.snapshot(),active:true,closing:false,chromeCloseRequested:false,chromeDisposed:false,shareBusy:false,informationBusy:false,saveBusy:false,previewIndex:-1,
    saveFeedback:null,saveController:new core.ReaderImageSaveController(),shareController:new core.ReaderImageShareController(),autoReadController:new core.ReaderAutoReadController(()=>{}),
    getUIContext:()=>({getPromptAction:()=>({showToast:v=>toasts.push(v.message)})}),invalidateChromeShow(){},input:null,entryTransition:null,
    mediaActions:null})
  s.saveController.subscribe(v=>s.saveBusy=v)
  return {s,toasts}
}
test('save/share/info mutual exclusion executes real guards and controller busy',async()=>{
  const session=await realSession(),{s}=surface(session),done=deferred();let calls=0
  s.mediaActions={imageSave:{prepare:async()=>{calls++;return {present:()=>done.promise,release(){}}}},imageShare:null,informationSupplement:null}
  for(const field of ['shareBusy','informationBusy']){s[field]=true;await s.saveImage('current');s[field]=false}
  assert.equal(calls,0)
  const run=s.saveImage('current');await tick();assert.equal(s.saveBusy,true)
  s.mediaActions={imageSave:s.mediaActions.imageSave,imageShare:{prepare:()=>{throw Error('share must not prepare')}},informationSupplement:null}
  await s.shareImage();await s.showInformation(session.snapshot().frames[0]);await s.saveImage('current');assert.equal(calls,1)
  done.resolve([{sourceIndex:0,status:'saved'}]);await run;session.close()
})
test('dialog inactive completion defers feedback until active; disappear suppresses late toast',async()=>{
  for(const disappear of [false,true]) {
    const session=await realSession(),{s,toasts}=surface(session),done=deferred()
    s.mediaActions={imageSave:{prepare:async()=>({present:()=>{s.active=false;return done.promise},release(){}})},imageShare:null,informationSupplement:null}
    const run=s.saveImage('current');await tick()
    if(disappear)s.aboutToDisappear()
    done.resolve([{sourceIndex:0,status:'saved'}]);await run;assert.deepEqual(toasts,[])
    s.active=true;s.flushSaveFeedback();assert.equal(toasts.length,disappear?0:1)
    s.flushSaveFeedback();assert.equal(toasts.length,disappear?0:1);session.close()
  }
})
test('both close intents cancel deferred prepare before presentation while surface is still active',async()=>{
  for(const hostClosing of [false,true]) {
    const session=await realSession(),{s,toasts}=surface(session),prepared=deferred();let shown=0,released=0
    s.onClose=()=>{}
    s.mediaActions={imageSave:{prepare:()=>prepared.promise},imageShare:null,informationSupplement:null}
    const run=s.saveImage('current')
    if(hostClosing){s.closing=true;s.onClosingChanged()}else s.requestClose()
    assert.equal(s.active,true)
    prepared.resolve({present:async()=>{shown++;return [{sourceIndex:0,status:'saved'}]},release:()=>released++})
    await run;assert.equal(shown,0);assert.equal(released,1);assert.deepEqual(toasts,[])
    session.close()
  }
})
test('both close intents retain already presented resources and suppress completion feedback',async()=>{
  for(const hostClosing of [false,true]) {
    const session=await realSession(),{s,toasts}=surface(session),done=deferred();let released=0
    s.onClose=()=>{}
    s.mediaActions={imageSave:{prepare:async()=>({present:()=>done.promise,release:()=>released++})},imageShare:null,informationSupplement:null}
    const run=s.saveImage('current');await tick()
    if(hostClosing){s.closing=true;s.onClosingChanged()}else s.requestClose()
    assert.equal(released,0)
    done.resolve([{sourceIndex:0,status:'saved'}]);await run
    assert.equal(released,1);assert.deepEqual(toasts,[]);s.flushSaveFeedback();assert.deepEqual(toasts,[])
    session.close()
  }
})
