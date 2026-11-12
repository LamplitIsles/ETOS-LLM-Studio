import * as Crypto from 'expo-crypto';
import { fetch as nativeFetch } from 'expo/fetch';
import { ChatController } from './chat';
import { NativeAuth, httpsOrigin } from './native-auth';
import { pendingStore } from './pending-store';
import { nativeTransport } from './transport';

export function createNativeChat(value: string, auth: NativeAuth) {
  const origin = httpsOrigin(value);
  const transport = nativeTransport(origin, auth, nativeFetch as typeof fetch);
  return { controller: new ChatController(origin, transport.socket, pendingStore, () => Crypto.randomUUID(), undefined, transport.checkAuthorization), media: transport };
}
