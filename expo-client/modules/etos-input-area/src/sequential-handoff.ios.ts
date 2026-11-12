import { requireOptionalNativeModule } from 'expo';
import { beginSequential, cancelSequential, enableSequential, disableSequential, abandonSequential, snapshotSequential, inspectSequential, sequentialAvailable, recoveryAvailable, type SequentialArgs, type SequentialNative } from './sequential-handoff-core';
const module = () => requireOptionalNativeModule<SequentialNative>('ETOSInputArea');
export function sequentialHandoffAvailable() { return sequentialAvailable(module()); }
export function firstTapAndAbandonAvailable() { return recoveryAvailable(module()); }
export function enableSequentialHandoff(panel:number,generation:number) { return enableSequential(panel,generation,module()); }
export function disableSequentialHandoff(panel:number,generation:number) { return disableSequential(panel,generation,module()); }
export function abandonSequentialHandoff(panel:number,generation:number,operation:number) { return abandonSequential(panel,generation,operation,module()); }
export function snapshotSequentialHandoff(host:number,panel:number,input:number,generation:number,current:()=>boolean) { return snapshotSequential(host,panel,input,generation,current,module()); }
export function beginSequentialHandoff(args: SequentialArgs) { return beginSequential(args, module()); }
export function cancelSequentialHandoff(panel: number, generation: number, operation: number) { return cancelSequential(panel, generation, operation, module()); }
export function inspectSequentialHandoff(panel: number, generation: number, operation: number) { return inspectSequential(panel, generation, operation, module()); }
export { sanitizeSequentialEvent } from './sequential-handoff-core';
export type { SequentialArgs, SequentialEvent } from './sequential-handoff-core';
