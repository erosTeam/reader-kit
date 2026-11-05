const test = require('node:test'), assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm'), path = require('node:path')
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript')
const exports_ = {}
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname, '../reader-ui/src/main/ets/ReaderPagerIdentityMap.ets'), 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, { exports: exports_ })
const singles = n => Array.from({ length:n }, (_, i) => `${i}:whole`)
const spreads = n => Array.from({ length:n/2 }, (_, i) => `${i*2}:whole+${i*2+1}:whole`)
function unique(items) { assert.equal(new Set(items.map(x=>x.nativeKey)).size, items.length) }
test('first, far and second source preserve the visible native viewport through spread roundtrip', () => {
 for (const source of [0,1,244,245]) {
  const m = new exports_.ReaderPagerIdentityMap()
  const first = m.update(singles(300), source, 1, 'unit-a')
  const native = first[source].nativeKey
  const paired = m.update(spreads(300), Math.floor(source/2), 2, 'unit-a')
  assert.equal(paired[Math.floor(source/2)].nativeKey, native); unique(paired)
  const back = m.update(singles(300), source, 3, 'unit-a')
  assert.equal(back[source].nativeKey, native); unique(back)
 }
})
test('ordinary navigation updates the selected owner without replacing item data', () => {
 const m = new exports_.ReaderPagerIdentityMap(), a=m.update(singles(10),0,1,'a')
 assert.equal(m.update(singles(10),7,1,'a'),a)
 assert.equal(m.update(spreads(10),3,2,'a')[3].nativeKey,a[7].nativeKey)
})
test('unrelated source, unit and fragments cannot borrow the selected viewport identity', () => {
 const m = new exports_.ReaderPagerIdentityMap(), a=m.update(['0:left','0:right','1:whole'],1,1,'a')
 const b=m.update(['0:whole','1:whole'],0,2,'a')
 assert.notEqual(b[0].nativeKey,a[1].nativeKey);assert.equal(b[1].nativeKey,a[2].nativeKey);unique(b)
 const c=m.update(['0:whole','1:whole'],0,2,'b')
 assert.notEqual(c[0].nativeKey,b[0].nativeKey);unique(c)
})
test('live spread alignment preserves overlapping selected image without duplicate keys', () => {
 const m=new exports_.ReaderPagerIdentityMap(), a=m.update(['0:whole+1:whole','2:whole+3:whole','4:whole'],1,1,'a')
 const b=m.update(['0:whole','1:whole+2:whole','3:whole+4:whole'],1,2,'a')
 assert.equal(b[1].nativeKey,a[1].nativeKey);unique(b)
})

test('native datasource publishes a matching map before reload and retains observable item identity', () => {
 const file=path.join(__dirname,'../reader-ui/src/main/ets/ReaderPagerSurface.ets')
 const source=fs.readFileSync(file,'utf8'), tree=ts.createSourceFile(file,source,ts.ScriptTarget.Latest,true)
 const names=['ReaderPagerRenderItem','ReaderPagerDataSource']
 const classes=names.map(name=>tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.getText(tree)===name).getText(tree)).join('\n')
 const out={}
 vm.runInNewContext(ts.transpileModule(classes+'\nexports.Source=ReaderPagerDataSource', {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,experimentalDecorators:true}}).outputText,{exports:out,ObservedV2:c=>c,Trace:()=>undefined,DataOperationType:{ADD:'add',RELOAD:'reload'}})
 const ids=new exports_.ReaderPagerIdentityMap(), ds=new out.Source()
 let reloads=0, expectedIndex=244, expectedKey='244:whole'
 const listener={onDatasetChange(operations){assert.equal(operations.length,1);assert.equal(operations[0].type,'reload');reloads++;assert.equal(ds.getData(expectedIndex).key,expectedKey);assert.equal(ds.getData(expectedIndex).snapshot.displayIndex,expectedIndex)}}
 ds.registerDataChangeListener(listener)
 const first={displayIndex:244}
 ds.update(ids.update(singles(300),244,1,'a'),first)
 const selected=ds.getData(244)
 expectedIndex=122;expectedKey='244:whole+245:whole'
 ds.update(ids.update(spreads(300),122,2,'a'),{displayIndex:122})
 assert.equal(ds.getData(122),selected)
 assert.equal(reloads,2)
 const arrival={displayIndex:122,frames:['ready']}
 ds.update(ids.update(spreads(300),122,2,'a'),arrival)
 assert.equal(ds.getData(122),selected);assert.equal(selected.snapshot,arrival)
 assert.equal(reloads,2,'image delivery must not request structural refresh')
 expectedIndex=123;expectedKey='246:whole+247:whole'
 ds.update(ids.update(spreads(300),123,2,'a'),{displayIndex:123})
 assert.equal(reloads,2,'ordinary page navigation must not reload the native data')
 ds.unregisterDataChangeListener(listener)
 ds.update(ids.update(singles(300),246,3,'a'),{displayIndex:246})
 assert.equal(reloads,2)
 const beforeInsert=ds.getData(246), batches=[]
 ds.registerDataChangeListener({onDatasetChange(operations){batches.push(JSON.parse(JSON.stringify(operations)))}})
 const keys=[...Array.from({length:12},(_,i)=>`previous-${i}`),...singles(300),'next-0','next-1']
 ds.update(ids.update(keys,258,3,'a'),{displayIndex:246})
 assert.equal(ds.getData(258),beforeInsert,'the selected viewport retains its observable identity')
 assert.deepEqual(batches,[[{type:'add',index:0,count:12},{type:'add',index:312,count:2}]])
 ds.update(ids.update(keys,258,3,'a'),{displayIndex:246,frames:['updated']})
 assert.equal(batches.length,1,'image updates do not publish another structural event')
})


test('adjacent chapter insertion preserves keyed native pages within the same work and topology', () => {
 const map = new exports_.ReaderPagerIdentityMap()
 const first = map.update(['A0','A1'],1,7,'work')
 const next = map.update(['P0','A0','A1','B0'],2,7,'work')
 assert.equal(next[2].nativeKey, first[1].nativeKey)
 assert.equal(next[1].nativeKey, first[0].nativeKey)
 assert.notEqual(next[0].nativeKey,next[3].nativeKey)
 assert.equal(map.update(['P0','A0','A1','B0'],3,7,'work'),next)
 unique(next)
})


test('an old native echo cannot take a newer press or cancel its real reverse turn', () => {
 const text=fs.readFileSync(path.join(__dirname,'../reader-ui/src/main/ets/ReaderPagerSurface.ets'),'utf8')
 const touch=text.slice(text.indexOf('  private handleBoundaryTouch('),text.indexOf('  aboutToAppear()',text.indexOf('struct ReaderNativePager')))
 const turn=text.slice(text.indexOf('class ReaderNativeTurn'),text.indexOf('@ComponentV2\nstruct ReaderNativePager'))
 const selection=text.slice(text.indexOf('  onCommandChanged()'),text.indexOf('  build() {',text.indexOf('  private queueSelection(')))
 const tasks=new Map();let serial=0
 const out={}
 const compiled=ts.transpileModule(`${turn} export class Pager { ${touch} ${selection} }`, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText
 vm.runInNewContext(compiled,{exports:out,TouchType:{Down:0,Up:1,Cancel:2},console:{info(){}},setTimeout:fn=>{tasks.set(++serial,fn);return serial},clearTimeout:id=>tasks.delete(id)})
 const down=p=>p.handleBoundaryTouch({type:0,touches:[{}],changedTouches:[{windowX:40,windowY:100}]})
 const claim=(p,from,to)=>{p.noteNativeSwipe(from);p.claimNativeSwipe(from,to)}
 const flush=()=>{const pending=[...tasks.values()];tasks.clear();pending.forEach(fn=>fn())}
 const fixture=()=>{
  const p=new out.Pager(), selected=[]
  Object.assign(p,{active:true,inputLocked:false,moving:false,gestureTopology:-1,gestureNavigation:-1,gestureSerial:0,pendingChange:0,
   swipeSerial:-1,swipeSourceKey:'',carriedSwipeSourceKey:'',claimedTurn:null,lastCommandSerial:0,
   snapshot:{phase:'ready',pagerIndex:1,pagerKeys:['a','b','c','d'],topologyRevision:7,navigationRevision:10},
   boundarySwipe:{begin(){},cancel(){}},onSelect(index,topology,navigation){selected.push(index);p.snapshot={...p.snapshot,pagerIndex:index,navigationRevision:navigation+1}}})
  return {p,selected}
 }
 for(const newerDown of ['before-change','after-change','after-commit']) {
  const {p,selected}=fixture()
  down(p);claim(p,1,2)
  if(newerDown==='before-change')down(p)
  p.queueSelection(2)
  if(newerDown==='after-change')down(p)
  // A current-index layout echo can arrive before the queued selection is published.
  p.queueSelection(1)
  flush();assert.deepEqual(selected,[2])
  if(newerDown==='after-commit')down(p)
  p.queueSelection(1);flush()
  assert.deepEqual(selected,[2], 'a stale callback during the next press cannot consume it')
  claim(p,2,1)
  p.queueSelection(1)
  p.queueSelection(3);flush()
  assert.deepEqual(selected,[2,1], 'only the real reverse target can commit')
  p.queueSelection(2);flush()
  assert.deepEqual(selected,[2,1], 'a committed turn is single-use')
 }
 const {p,selected}=fixture()
 p.command={serial:1,targetKey:'c',targetIndex:2,topologyRevision:7,navigationRevision:10}
 p.controller={changeIndex(index,animated){assert.equal(index,2);assert.equal(animated,true)}}
 p.onCommandChanged()
 p.snapshot={...p.snapshot,pagerIndex:2,pagerKeys:['before','a','b','c','d']}
 p.queueSelection(1);p.queueSelection(3);flush()
 assert.deepEqual(selected,[3], 'command acceptance follows the stable key after preceding rows are inserted')
 const interrupted=fixture()
 down(interrupted.p);claim(interrupted.p,1,2)
 down(interrupted.p);interrupted.p.finishNativeAnimation(1)
 interrupted.p.queueSelection(2);flush()
 assert.deepEqual(interrupted.selected, [], 'a turn that ended back at its source cannot be replayed')
 const rapid=fixture()
 down(rapid.p);claim(rapid.p,1,2);rapid.p.queueSelection(2)
 down(rapid.p);claim(rapid.p,2,1);rapid.p.queueSelection(1)
 flush()
 assert.deepEqual(rapid.selected, [], 'a real return to the current page beats the queued forward turn')
 const overlapping=fixture()
 down(overlapping.p);claim(overlapping.p,1,2);overlapping.p.queueSelection(2)
 down(overlapping.p);claim(overlapping.p,2,3);overlapping.p.finishNativeAnimation(2)
 flush();overlapping.p.queueSelection(3);flush()
 assert.deepEqual(overlapping.selected,[2,3], 'the previous animation can end at the new turn’s source')
 const delayed=fixture()
 const commit=delayed.p.onSelect
 let publish
 delayed.p.onSelect=(...args)=>{publish=()=>commit(...args)}
 down(delayed.p);claim(delayed.p,1,2);delayed.p.queueSelection(2)
 down(delayed.p);flush()
 claim(delayed.p,2,3)
 publish();delayed.p.onSelect=commit
 delayed.p.queueSelection(3);flush()
 assert.deepEqual(delayed.selected,[2,3], 'the next gesture can claim from the selected native page before snapshot propagation')
})
