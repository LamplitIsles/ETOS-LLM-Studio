import { ChatController } from './chat';
import { pendingStore } from './pending-store';
import { webTransport } from './transport';

export function createWebChat() {
  const origin = window.location.origin;
  const transport = webTransport(origin);
  return { controller: new ChatController(origin, transport.socket, pendingStore, () => crypto.randomUUID(), undefined, transport.checkAuthorization), media: transport };
}
