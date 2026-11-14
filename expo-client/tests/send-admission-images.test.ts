import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import { beginSendDrafts } from '../src/cfl/composer';
import { createFixture } from './fixtures/fixture';
import { fixtureImageBase64 } from './fixtures/fixture-art';
import type { AttachmentDraft } from '../src/cfl/drafts';
import type { ChatView, Receipt } from '../vendor/contracts/src/index';

register(new URL('./send-admission-image-loader.mjs', import.meta.url));
const operationId = '00000000-0000-4000-8000-000000000001';
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
const bytes = Uint8Array.from(atob(fixtureImageBase64), c => c.charCodeAt(0));
function draft(kind: 'image' | 'file', id: string, name: string): AttachmentDraft {
  const body = kind === 'image' ? new Blob([bytes], {type:'image/png'}) : new Blob(['fixture'], {type:'text/plain'});
  return { id, kind, name, body, size:body.size, mediaType:body.type, uri:'fixture://local', width:40, height:40, release() {} };
}

for (const order of ['view-first', 'receipt-first'] as const) test(`admission keeps upload identities when ${order} and the observed message has only the second image`, async () => {
  const fixture = createFixture(), initial = fixture.read();
  let entries:Pending[] = [], firstSave:Pending[] = [], update!: (v: ChatView) => void, sent = 0;
  const store:PendingStore={async load(){return entries}, async save(_o,next){entries=next; if (!firstSave.length && next.length) firstSave=structuredClone(next)}};
  let deliver!: (receipt:Receipt) => void;
  const reply = new Promise<Receipt>(resolve => { deliver=resolve });
  let messageView!: ChatView;
  const port:ChatPort={async history(){return {messages:[],before:null}},async submit(input){
    sent++; assert.equal(input.images?.length,2);assert.equal(input.files?.length,1);
    messageView={...initial,messages:[...initial.messages,{id:'server-message',role:'user',text:input.text,operationId,turnId:null,createdAt:1,images:[input.images![1]]}]};
    if(order==='view-first') update(messageView);
    return reply;
  },async lookup(){return null},close(){}};
  const controller=new ChatController('fixture-origin',async()=>({close(){}} as WebSocket),store,()=>operationId,async(_s,changed)=>{update=changed;changed(initial);return port});
  await controller.start();
  const selected=[draft('image','img-a','a.png'),draft('file','doc-a','doc.txt'),draft('image','img-b','b.png')];
  const admission=await beginSendDrafts(controller,fixture.media,'synthetic',selected,{snapshot:controller.snapshot(),after:null});
  assert.equal(admission.operationId,operationId);
  assert.deepEqual(admission.images?.map(x=>x.name),['a.png','b.png']);
  assert.deepEqual(admission.files?.map(x=>x.name),['doc.txt']);
  assert.deepEqual(admission.images,firstSave[0].images);assert.deepEqual(admission.files,firstSave[0].files);
  const imageId=admission.images![1].attachmentId;
  if (order === 'receipt-first') {
    admission.images![0].name='changed'; admission.files![0].name='changed';
    assert.equal(entries[0].images?.[0].name,'a.png'); assert.equal(entries[0].files?.[0].name,'doc.txt');
    admission.images![0].name='a.png'; admission.files![0].name='doc.txt';
  }
  if(order==='receipt-first') { deliver({operationId,attempt:1,state:'submitted',messageId:'server-message',turnId:null,error:null}); await tick(); update(messageView); }
  else deliver({operationId,attempt:1,state:'submitted',messageId:'server-message',turnId:null,error:null});
  await tick();await tick();
  assert.equal(controller.snapshot().pending.some(x=>x.operationId===operationId),false);
  assert.deepEqual(controller.snapshot().view?.messages.at(-1)?.images?.map(x=>x.attachmentId),[imageId]);
  assert.deepEqual(admission.images?.map(x=>x.name),['a.png','b.png']);
  // The caller can build an exact draft-ID -> attachment-ID map once, without the partial server list.
  assert.deepEqual(selected.filter(x=>x.kind==='image').map((d,i)=>[d.id,admission.images![i].attachmentId]),[['img-a',firstSave[0].images![0].attachmentId],['img-b',imageId]]);
  assert.equal(sent,1);controller.stop();
});
