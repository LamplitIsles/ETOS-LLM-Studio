import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Pending, PendingStore } from './chat';
import { validateSubmission } from '../../vendor/contracts/src/index';

/** Non-secret message recovery journal; namespaced by exact CFL origin. */
export const pendingStore: PendingStore = {
  async load(origin) {
    const text = await AsyncStorage.getItem(`ETOS.Expo.pending:${origin}`);
    if (!text) return [];
    const value: unknown = JSON.parse(text);
    if (!Array.isArray(value) || value.some(x => !x || x.origin !== origin || typeof x.sessionId !== 'string' || typeof x.operationId !== 'string' || typeof x.text !== 'string' || !['unknown', 'submitted', 'failed'].includes(x.state))) throw new Error('invalid_journal');
    for (const x of value) validateSubmission({ operationId: x.operationId, text: x.text, ...('images' in x ? { images: x.images } : {}), ...('files' in x ? { files: x.files } : {}) });
    return value as Pending[];
  },
  async save(origin, entries) { await AsyncStorage.setItem(`ETOS.Expo.pending:${origin}`, JSON.stringify(entries)); },
};
