import { beginSequential, cancelSequential, enableSequential, disableSequential, snapshotSequential, inspectSequential, type SequentialArgs } from './sequential-handoff-core';
export function sequentialHandoffAvailable() { return false; }
export function enableSequentialHandoff(panel:number,generation:number) { return enableSequential(panel,generation,null); }
export function disableSequentialHandoff(panel:number,generation:number) { return disableSequential(panel,generation,null); }
export function snapshotSequentialHandoff(host:number,panel:number,input:number,generation:number,current:()=>boolean) { return snapshotSequential(host,panel,input,generation,current,null); }
export function beginSequentialHandoff(args: SequentialArgs) { return beginSequential(args, null); }
export function cancelSequentialHandoff(panel: number, generation: number, operation: number) { return cancelSequential(panel, generation, operation, null); }
export function inspectSequentialHandoff(panel: number, generation: number, operation: number) { return inspectSequential(panel, generation, operation, null); }
export { sanitizeSequentialEvent } from './sequential-handoff-core';
export type { SequentialArgs, SequentialEvent } from './sequential-handoff-core';
