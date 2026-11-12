import type { KeyboardPanelResult } from '../../modules/etos-input-area/src/keyboard-panel-core';
import type { SequentialEvent } from '../../modules/etos-input-area/src/sequential-handoff-core';

type Mode = 'panel' | 'keyboard' | 'dismiss';
type Identity = { panel: number; generation: number; operation: number };
type Pending = Identity & { mode: Mode; current: () => boolean; finish: (result: KeyboardPanelResult) => void; unconfirmed: boolean; cancelled: boolean };

// The native event and acknowledgement can arrive in either order. An unknown
// acknowledgement retains the exact operation for explicit abandonment.
export class SequentialPanelGate {
  private pending: Pending | null = null;
  private panelOwner: Identity | null = null;

  run(identity: Identity, mode: Mode, current: () => boolean, begin: () => Promise<{ status: string }>): Promise<KeyboardPanelResult> {
    if (this.pending) return Promise.resolve({ status: 'targets_unavailable' });
    let finish!: (value: KeyboardPanelResult) => void;
    const completed = new Promise<KeyboardPanelResult>(resolve => { finish = resolve; });
    const pending: Pending = { ...identity, mode, current, finish, unconfirmed: false, cancelled: false };
    this.pending = pending;
    void Promise.resolve().then(() => this.pending === pending && current() ? begin() : { status: 'session_changed' }).catch(() => ({ status: 'unknown' })).then(started => {
      if (started.status === 'requested' || this.pending !== pending) return;
      const uncertain = ['unknown', 'session_changed', 'focus_unknown', 'focus_refused', 'resign_refused'].includes(started.status);
      if (uncertain) pending.unconfirmed = true;
      else this.pending = null;
      finish({ status: started.status === 'session_changed' ? 'session_changed' : uncertain ? 'unavailable' : 'targets_unavailable' });
    });
    return completed;
  }

  receive(event: SequentialEvent): 'panel' | 'closed' | 'owner_lost' | null {
    const pending = this.pending;
    if (this.panelOwner?.generation === event.generation && this.panelOwner.operation === event.operation && event.status === 'owner_lost') {
      this.panelOwner = null; return 'owner_lost';
    }
    if (!pending) return null;
    if (pending.generation !== event.generation || pending.operation !== event.operation || !pending.current() || pending.unconfirmed) return null;
    if (event.status === 'cancelled') { pending.cancelled = true; return null; }
    if (event.status === 'drained') {
      this.pending = null; pending.finish({ status: 'targets_unavailable' });
      if (pending.mode !== 'panel' && this.panelOwner) { this.panelOwner = null; return 'owner_lost'; }
      return null;
    }
    if (!pending.cancelled && (event.status === 'shown' || event.status === 'hidden')) {
      this.pending = null; pending.finish({ status: 'requested' });
      if (event.status === 'shown' && pending.mode === 'panel') {
        this.panelOwner = { panel: pending.panel, generation: pending.generation, operation: pending.operation }; return 'panel';
      }
      this.panelOwner = null; return 'closed';
    }
    if (event.status === 'focus_unknown' || event.status === 'focus_refused' || event.status === 'resign_refused') {
      pending.unconfirmed = true; pending.finish({ status: 'unavailable' });
    }
    return null;
  }

  abandon(generation?: number): Identity | null {
    const pending = this.pending;
    if (!pending || (generation !== undefined && pending.generation !== generation)) return null;
    this.pending = null; pending.finish({ status: 'session_changed' });
    return { panel: pending.panel, generation: pending.generation, operation: pending.operation };
  }
}
