/**
 * Shared webhook plumbing: idempotent event_log receipt around each provider event.
 * log_webhook_event -> (duplicate? stop) -> handler -> finish_webhook_event(processed|ignored|failed).
 * A failed event answers 500 so the provider retries; a processed duplicate answers 200 and does nothing.
 */
import type { Rpc } from './crm-tools.ts';
import type { InboundDeps } from './inbound.ts';

export interface WebhookDeps extends InboundDeps { rpc: Rpc }

export async function withEventLog(rpc: Rpc, provider: string, externalId: string, type: string, payload: unknown, now: Date,
  fn: () => Promise<{ status: 'processed' | 'ignored'; dealerId?: string | null }>): Promise<'processed' | 'ignored' | 'duplicate'> {
  const ev = (await rpc<{ event_id: string; duplicate: boolean }[]>('log_webhook_event', { p_provider: provider, p_external_id: externalId, p_event_type: type, p_payload: payload, p_now: now.toISOString() }))[0];
  if (ev.duplicate) return 'duplicate';
  try {
    const r = await fn();
    await rpc('finish_webhook_event', { p_event_id: ev.event_id, p_status: r.status, p_error: null, p_dealer_id: r.dealerId ?? null, p_now: now.toISOString() });
    return r.status;
  } catch (e) {
    await rpc('finish_webhook_event', { p_event_id: ev.event_id, p_status: 'failed', p_error: (e as Error).message, p_dealer_id: null, p_now: now.toISOString() }).catch(() => undefined);
    throw e;
  }
}
