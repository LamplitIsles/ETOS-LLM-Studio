import type { ChatController, OperationIdentity, OperationState } from './chat';

export type SendOutcome = OperationIdentity & { state: OperationState };
/** Only durable receipts or a matching visible message establish an outcome. */
export async function outcome(controller: ChatController, task: Promise<string>): Promise<SendOutcome> {
  const current = controller.scope(), sessionId = controller.snapshot().view?.sessionId ?? '';
  const operationId = await task;
  const identity = { origin: controller.origin, sessionId, operationId };
  if (!current()) return { ...identity, state: 'unknown' };
  const state = await controller.operationStatus(identity);
  return { ...identity, state: current() ? state : 'unknown' };
}
