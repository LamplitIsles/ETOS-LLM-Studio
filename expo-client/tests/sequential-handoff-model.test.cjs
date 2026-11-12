const {test}=require('node:test');const assert=require('node:assert/strict');
// Test-owned model of Swift owner: observed hide, target focus, then user cancels.
// It exercises state ordering, not UIKit notification delivery or Swift code.
class Owner {
  constructor(patched){this.patched=patched;this.pending=null;this.claims=[];}
  begin(id){if(this.pending)return 'busy';this.pending={id,phase:'hide',cancelled:false,will:false};return 'requested';}
  willHide(){if(this.pending?.phase==='hide')this.pending.will=true;}
  didHide(){const p=this.pending;if(!p||p.phase!=='hide'||!p.will)return;if(p.cancelled){this.pending=null;return;}this.claims.push(p.id);p.phase='show';}
  cancel(){const p=this.pending;if(!p)return;if(p.phase==='show'){if(!this.patched){this.pending=null;return;}p.phase='hide';p.will=false;p.cancelled=true;}else p.cancelled=true;}
}
test('normal first hide makes progress in isolated model',()=>{const x=new Owner(true);assert.equal(x.begin(1),'requested');x.willHide();x.didHide();assert.deepEqual(x.claims,[1]);});
test('old immediate unlock permits late didHide to enter next operation: red',()=>{const x=new Owner(false);x.begin(1);x.willHide();x.didHide();x.cancel();assert.equal(x.begin(2),'requested');x.willHide();x.didHide();assert.deepEqual(x.claims,[1,2]);});
test('draining canceled hide prevents new operation until real old hide observed',()=>{const x=new Owner(true);x.begin(1);x.willHide();x.didHide();x.cancel();assert.equal(x.begin(2),'busy');x.willHide();assert.equal(x.begin(2),'busy');x.didHide();assert.equal(x.begin(2),'requested');x.willHide();x.didHide();assert.deepEqual(x.claims,[1,2]);});
test('missing actual hide remains busy, no timer or retry',()=>{const x=new Owner(true);x.begin(1);x.willHide();x.didHide();x.cancel();x.willHide();assert.equal(x.begin(2),'busy');});
