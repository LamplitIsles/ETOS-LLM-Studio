import { requireOptionalNativeModule } from 'expo';
import { runInputAreaProbe, type InputAreaProbeArgs } from './probe-core';

export function probeInputAreaTargets(args: InputAreaProbeArgs) {
  const module = requireOptionalNativeModule<{ probeTargets: (hostTag: number, scrollTag: number, inputTag: number) => Promise<unknown> }>('ETOSInputArea');
  return runInputAreaProbe(args, module);
}
