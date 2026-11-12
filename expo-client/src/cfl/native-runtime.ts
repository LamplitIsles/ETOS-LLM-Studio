import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import * as WebBrowser from 'expo-web-browser';
import { fetch as nativeFetch } from 'expo/fetch';
import { CALLBACK, NativeAuth, type Grant, type GrantStore } from './native-auth';

const options = { keychainService: 'ETOS.Expo.CFL.OAuth', keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY };
const key = async (origin: string) => `cfl.${await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, origin)}`;
const store: GrantStore = {
  async load(origin) { const value = await SecureStore.getItemAsync(await key(origin), options); return value ? JSON.parse(value) as Grant : null; },
  async save(origin, grant) { await SecureStore.setItemAsync(await key(origin), JSON.stringify(grant), options); },
  async remove(origin) { await SecureStore.deleteItemAsync(await key(origin), options); },
};
function base64url(hex: string) {
  const bytes = hex.match(/../g)!.map(pair => String.fromCharCode(parseInt(pair, 16))).join('');
  return btoa(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function createNativeAuth() {
  return new NativeAuth({
    store,
    random: async () => (await Crypto.getRandomBytesAsync(32)).reduce((s, b) => s + b.toString(16).padStart(2, '0'), ''),
    challenge: async verifier => base64url(await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, verifier)),
    browser: async url => { const result = await WebBrowser.openAuthSessionAsync(url, CALLBACK); return result.type === 'success' ? result.url : null; },
    fetch: nativeFetch as typeof fetch,
    now: Date.now,
  });
}
