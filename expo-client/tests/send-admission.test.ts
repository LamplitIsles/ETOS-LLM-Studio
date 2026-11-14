import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import { beginSendDrafts, beginSendSticker, sendDrafts } from '../src/cfl/composer';
import { AdmissionError } from '../src/cfl/chat';
import { createFixture } from './fixtures/fixture';
import type { AttachmentDraft } from '../src/cfl/drafts';
import type { ChatView, Receipt } from '../vendor/contracts/src/index';
import type { ApiTransport } from '../src/cfl/transport';
const id = '00000000-0000-4000-8000-000000000001';
function gate<T>() { let resolve!: (value:T)=>void; const promise = new Promise<T>(r => { resolve = r }); return {promise, resolve}; }
const turn = () => new Promise<void>(r => setImmediate(r));
test('durable local pending should release composer before receipt arrives', async () => {
  const journal=gate<void>(), journalStarted=gate<void>(), dispatched=gate<void>(), receipt=gate<Receipt>();
  let stored:Pending[]=[]; let calls=0; let settled=false;
  const store:PendingStore={async load(){return stored},async save(_origin,next){journalStarted.resolve();await journal.promise;stored=next}};
  const view:ChatView={version:2,sessionId:'fixture-session',name:'fixture',activeTurnId:null,contextUsage:{tokens:null,capacity:null},compaction:null,messages:[],before:null,capabilities:{text:true,steer:true,stop:true,images:false}};
  const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){calls++;dispatched.resolve();return receipt.promise},async lookup(){return null},close(){}};
  const controller=new ChatController('fixture-origin',async()=>({close(){}} as WebSocket),store,()=>id,async(_socket,changed)=>{changed(view);return port});
  await controller.start();
  const send=beginSendDrafts(controller,{} as ApiTransport,'synthetic text',[], { snapshot:controller.snapshot(), after: null }).then(value=>{settled=true;return value});
  await journalStarted.promise;
  assert.equal(controller.snapshot().pending.length,0,'journal gate must hold back pending');
  assert.equal(calls,0,'journal gate must hold back dispatch');
  journal.resolve(); await dispatched.promise; await turn();
  assert.equal(stored.length,1); assert.equal(controller.snapshot().pending[0]?.operationId,id); assert.equal(calls,1);
  const localAcceptedBeforeReceipt=settled;
  receipt.resolve({operationId:id,attempt:1,state:'submitted',messageId:'fixture-message',turnId:null,error:null});
  const accepted = await send; controller.stop();
  assert.equal(localAcceptedBeforeReceipt,true,'durable pending visible, but the caller still waits for receipt');
  assert.equal((accepted as {operationId:string}).operationId,id);
});

const idFor = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const makeView = (sessionId = 'fixture-session'): ChatView => ({version:2,sessionId,name:'fixture',activeTurnId:null,contextUsage:{tokens:null,capacity:null},compaction:null,messages:[],before:null,capabilities:{text:true,steer:true,stop:true,images:false}});
const makeReceipt = (operationId:string): Receipt => ({operationId,attempt:1,state:'submitted',messageId:'fixture-message',turnId:null,error:null});
function harness(store:PendingStore, port:ChatPort, view = makeView()) {
  let update!: (v:ChatView)=>void, n=0;
  const controller = new ChatController('fixture-origin',async()=>({close(){}} as WebSocket),store,()=>idFor(++n),async(_socket,changed)=>{update=changed;changed(view);return port});
  return {controller, update:(v:ChatView)=>update(v)};
}
const noMedia = {} as ApiTransport;
test('gesture anchor survives preparation, concurrent sends and restart without waiting for receipt', async () => {
 let stored:Pending[]=[]; const first = gate<Receipt>(), second = gate<Receipt>(); let submits=0;
 const store:PendingStore={async load(){return stored},async save(_o,next){stored=structuredClone(next)}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){return ++submits===1?first.promise:second.promise},async lookup(){return null},close(){}};
 const h=harness(store,port,{...makeView(),streamingReply:{id:'live',turnId:null,createdAt:1,text:'回复',ends:[2]}}); await h.controller.start();
 const rowKey=JSON.stringify(['reply','fixture-session','live',0]);
 const anchor={snapshot:h.controller.snapshot(), after:rowKey};
 const a=beginSendDrafts(h.controller,noMedia,'one',[],anchor); anchor.after='mutated-after-gesture';
 const b=beginSendDrafts(h.controller,noMedia,'two',[],{snapshot:h.controller.snapshot(),after:rowKey});
 const [aa,bb]=await Promise.all([a,b]);
 assert.equal(submits,2); assert.deepEqual(stored.map(e=>e.anchor),[{after:rowKey},{after:rowKey,predecessor:aa.operationId}]);
 assert.deepEqual(h.controller.snapshot().pending.map(x=>x.operationId),[aa.operationId,bb.operationId]);
 h.controller.stop(); first.resolve(makeReceipt(aa.operationId));second.resolve(makeReceipt(bb.operationId)); await turn();
 await h.controller.start(); assert.deepEqual(h.controller.snapshot().pending.map(x=>x.anchor),stored.map(x=>x.anchor)); h.controller.stop();
});
test('failed preparation preserves caller resources and does not journal or dispatch',async()=>{
 let stored:Pending[]=[],sent=0,released=0; const body=new Blob(['test'],{type:'text/plain'});
 const draft:AttachmentDraft={id:'fixture',kind:'file',name:'x.txt',size:body.size,body,mediaType:body.type,uri:'fixture://file',release(){released++}};
 const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();
 await assert.rejects(beginSendDrafts(h.controller,noMedia,'x',[draft],{snapshot:h.controller.snapshot(),after:null}),/files_unavailable/);
 assert.equal(stored.length,0);assert.equal(sent,0);assert.equal(released,0);h.controller.stop();
});
test('file preparation retains caller ownership across admission and receipt', async()=>{
 const fixture=createFixture();let stored:Pending[]=[],released=0;const response=gate<Receipt>();const body=new Blob(['test'],{type:'text/plain'});
 const draft:AttachmentDraft={id:'fixture',kind:'file',name:'x.txt',size:body.size,body,mediaType:body.type,uri:'fixture://file',release(){released++}};
 const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){return response.promise},async lookup(){return null},close(){}};
 const h=harness(store,port,fixture.read());await h.controller.start();const accepted=await beginSendDrafts(h.controller,fixture.media,'x',[draft],{snapshot:h.controller.snapshot(),after:null});
 assert.equal(stored[0].files?.length,1);assert.equal(released,0);response.resolve(makeReceipt(accepted.operationId));await turn();assert.equal(released,0);h.controller.stop();
});
test('ambiguous journal write carries identity, never dispatches and blocks overwrite until reload',async()=>{
 let stored:Pending[]=[],sent=0, fail=true; const store:PendingStore={async load(){return stored},async save(_o,next){stored=next;if(fail)throw Error('fixture ambiguous write')}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();
 await assert.rejects(beginSendDrafts(h.controller,noMedia,'x',[],{snapshot:h.controller.snapshot(),after:null}),e=>e instanceof AdmissionError && e.journal==='unknown' && !e.dispatched && e.identity.operationId===idFor(1));
 await assert.rejects(beginSendDrafts(h.controller,noMedia,'new',[],{snapshot:h.controller.snapshot(),after:null}),/journal_uncertain/);assert.equal(sent,0);assert.equal(stored.length,1);
 fail=false;await h.controller.start();assert.equal(h.controller.snapshot().pending[0].operationId,idFor(1));assert.equal(sent,0);h.controller.stop();
});
test('server identity changes during save: stored identity returned in error, never dispatches',async()=>{
 let stored:Pending[]=[],sent=0;const entered=gate<void>(),saving=gate<void>();
 const store:PendingStore={async load(){return stored},async save(_o,next){entered.resolve();await saving.promise;stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();const pending=beginSendDrafts(h.controller,noMedia,'x',[],{snapshot:h.controller.snapshot(),after:null});await entered.promise;
 h.update(makeView('other-server-session'));h.update(makeView());saving.resolve();
 await assert.rejects(pending,e=>e instanceof AdmissionError && e.journal==='stored' && !e.dispatched && e.message==='session_changed');
 assert.equal(stored.length,1);assert.equal(sent,0);h.controller.stop();await h.controller.start();assert.equal(h.controller.snapshot().pending.length,1);h.controller.stop();
});
test('legacy sendDrafts still waits for receipt; an unknown send is only looked up',async()=>{
 let stored:Pending[]=[],sent=0,lookup=0,settled=false;const response=gate<Receipt>();
 const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){sent++;return response.promise},async lookup(){lookup++;return null},close(){}};
 const h=harness(store,port);await h.controller.start();const send=sendDrafts(h.controller,noMedia,'x',[]).then(x=>{settled=true;return x});await turn();assert.equal(settled,false);
 response.resolve(makeReceipt(idFor(1)));assert.equal((await send).state,'submitted');assert.equal(sent,1);h.controller.stop();
});

test('sticker stage rejection is before admission and never submits',async()=>{
 let stored:Pending[]=[],sent=0,stage=0; const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const fixture=createFixture(),media:ApiTransport={...fixture.media,async request(){stage++;return new Response(null,{status:404})}};
 const h=harness(store,port,fixture.read());await h.controller.start();
 await assert.rejects(beginSendSticker(h.controller,media,{id:'fixture-sticker',version:'0'.repeat(64)},{snapshot:h.controller.snapshot(),after:null}),/sticker_unavailable/);
 assert.equal(stage,1);assert.equal(sent,0);assert.equal(stored.length,0);h.controller.stop();
});
test('sticker unknown result is admitted once and lookup never restages or resubmits',async()=>{
 let stored:Pending[]=[],sent=0,stage=0,lookup=0;const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){sent++;throw new Error('lost response')},async lookup(){lookup++;return null},close(){}};
 const fixture=createFixture(),media:ApiTransport={...fixture.media,async request(path,init){stage++;return fixture.media.request(path,init)}};
 const h=harness(store,port,fixture.read());await h.controller.start();
 const identity=await beginSendSticker(h.controller,media,{id:'fixture-sticker',version:'0'.repeat(64)},{snapshot:h.controller.snapshot(),after:null});await h.controller.reconcile();
 assert.equal(await h.controller.operationStatus(identity),'unknown');assert.equal(stage,1);assert.equal(sent,1);assert.ok(lookup>=1);assert.equal(stored[0].images?.[0].sticker?.id,'fixture-sticker');h.controller.stop();
});

test('stale snapshot and foreign predecessor fail before preparation or dispatch',async()=>{
 let stored:Pending[]=[],sent=0; const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();const old=h.controller.snapshot();h.update(makeView('other-server-session'));h.update(makeView());
 await assert.rejects(beginSendDrafts(h.controller,noMedia,'x',[],{snapshot:old,after:null}),/session_changed/);
 await assert.rejects(beginSendDrafts(h.controller,noMedia,'x',[],{snapshot:h.controller.snapshot(),after:null,predecessor:idFor(99)}),/invalid_anchor/);
 assert.equal(stored.length,0);assert.equal(sent,0);h.controller.stop();
});
test('stopping during save preserves stored identity and restart does not replay',async()=>{
 let stored:Pending[]=[],sent=0;const entered=gate<void>(),saving=gate<void>();
 const store:PendingStore={async load(){return stored},async save(_o,next){entered.resolve();await saving.promise;stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){sent++;return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();const pending=beginSendDrafts(h.controller,noMedia,'x',[],{snapshot:h.controller.snapshot(),after:null});await entered.promise;h.controller.stop();
 const restarted=h.controller.start();saving.resolve();
 await assert.rejects(pending,e=>e instanceof AdmissionError && e.journal==='stored' && !e.dispatched);await restarted;
 assert.equal(h.controller.snapshot().pending[0].operationId,idFor(1));assert.equal(sent,0);h.controller.stop();
});
test('legacy or malformed saved anchors fall back without fabricating placement',async()=>{
 const entries:Pending[]=[{origin:'fixture-origin',sessionId:'fixture-session',operationId:idFor(1),text:'old',createdAt:1,state:'unknown'},
 {origin:'fixture-origin',sessionId:'fixture-session',operationId:idFor(2),text:'bad',createdAt:2,state:'unknown',anchor:{after:42} as unknown as Pending['anchor']}];
 const store:PendingStore={async load(){return entries},async save(){}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(x){return makeReceipt(x.operationId)},async lookup(){return null},close(){}};
 const h=harness(store,port);await h.controller.start();assert.deepEqual(h.controller.snapshot().pending.map(e=>e.anchor),[undefined,undefined]);h.controller.stop();
});

test('anchor remains at the gesture when streaming advances during preparation',async()=>{
 let stored:Pending[]=[];const prepared=gate<{}>(),started=gate<void>(),receipt=gate<Receipt>();
 const store:PendingStore={async load(){return stored},async save(_o,next){stored=next}};
 const port:ChatPort={async history(){return {messages:[],before:null}},async submit(){return receipt.promise},async lookup(){return null},close(){}};
 const initial={...makeView(),streamingReply:{id:'live',turnId:null,createdAt:1,text:'一',ends:[1]}};
 const h=harness(store,port,initial);await h.controller.start();const oldKey=JSON.stringify(['reply','fixture-session','live',0]);
 const accepting=h.controller.beginPrepared('x',async()=>{started.resolve();return prepared.promise},{snapshot:h.controller.snapshot(),after:oldKey});await started.promise;
 h.update({...initial,streamingReply:{...initial.streamingReply,text:'一二',ends:[1,2]}});prepared.resolve({});const accepted=await accepting;
 assert.deepEqual(stored[0].anchor,{after:oldKey});receipt.resolve(makeReceipt(accepted.identity.operationId));await accepted.completion;h.controller.stop();
});
