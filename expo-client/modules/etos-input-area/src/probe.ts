import { runInputAreaProbe, type InputAreaProbeArgs } from './probe-core';

export function probeInputAreaTargets(args: InputAreaProbeArgs) {
  return runInputAreaProbe(args, null);
}
