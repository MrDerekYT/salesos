/** In-memory adapter for tests and local demos. Never registered in production unless SALESOS_ALLOW_MOCK_PROVIDER=true. */
import type { ChannelAdapter, OutboundMessage, SendResult } from './types.ts';

export interface MockAdapter extends ChannelAdapter { sent: OutboundMessage[]; nextResults: SendResult[] }
export function mockAdapter(idempotentRetries = true): MockAdapter {
  const a: MockAdapter = {
    provider: 'mock', channels: ['sms', 'whatsapp', 'email'], idempotentRetries, sent: [], nextResults: [],
    async send(m) {
      a.sent.push(m);
      return a.nextResults.shift() ?? { ok: true, providerMessageId: `mock-${a.sent.length}-${m.idempotencyKey}`, status: 'sent' };
    },
  };
  return a;
}
