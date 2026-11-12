import { isPrivateIPv4 } from './seed-address';

/** This does not authorize CFL; it only selects the local synthetic developer path. */
export function isDevelopmentSeedAllowed(dev: boolean, flag: string | undefined, origin: string | undefined, lanHost?: string): boolean {
  if (!dev || flag !== '1') return false;
  if (origin === 'http://localhost:8091' || origin === 'http://127.0.0.1:8091') return true;
  return isPrivateIPv4(lanHost) && origin === `http://${lanHost}:8091`;
}
