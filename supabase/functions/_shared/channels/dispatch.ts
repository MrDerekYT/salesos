/**
 * The only code path that hands a message to a provider. Order of operations for every send:
 *   get_send_target (no secrets) -> channel rules (WhatsApp window/template, email CAN-SPAM + one-click unsubscribe)
 *   -> claim_send_attempt(idempotency key) -> adapter.send -> complete_send_attempt.
 * Callers (sweeper, agent runner, keyword confirmations) have ALREADY passed the before-send chain + can_send(commit),
 * except system replies (STOP/HELP/START confirmations, staff command replies), which answer the sender's own message.
 * A retry with the same key never double-sends: 'already_sent' returns the first provider id; a crash mid-send on a
 * provider without idempotency keys becomes 'unknown' and goes to a person instead of being re-sent blindly.
 */
import type { Channel, Purpose, SendKind } from '../before-send.ts';
import type { Rpc } from '../crm-tools.ts';
import type { AdapterRegistry } from './registry.ts';
import { NetworkError, type NumberConfig, type OutboundMessage, type SendResult } from './types.ts';

export interface DispatchRequest {
  numberId: string; contactId: string; body: string; idempotencyKey: string;
  purpose: Purpose; kind: SendKind | 'system';
  draftId?: string | null;
  template?: { name: string; language: string; params: string[] } | null;
  subject?: string | null;
}
export type DispatchResult =
  | { ok: true; providerMessageId: string; deduped?: boolean }
  | { ok: false; error: string; retryable: boolean; detail?: string };

export interface SendTargetRow {
  dealer_id: string; dealer_name: string; postal_address: string | null; main_phone: string | null;
  number: { id: string; channel: Channel; provider: string; address: string; status: string; config: NumberConfig };
  contact: { id: string; first_name: string | null; phone_e164: string | null; email: string | null };
  whatsapp_window_open: boolean;
  email_suppressed?: boolean;
}
export interface Dispatcher {
  send(r: DispatchRequest): Promise<DispatchResult>;
  /** Staff command replies: the recipient is a verified staff identity, not a contact. */
  sendRaw(r: { dealerId: string; number: { id: string; channel: Channel; provider: string; address: string; config: NumberConfig }; to: string; body: string; idempotencyKey: string }): Promise<DispatchResult>;
}
export interface DispatcherOptions { rpc: Rpc; registry: AdapterRegistry; unsubscribeBaseUrl?: string | null; now?: () => Date; log?: (e: string, d: Record<string, unknown>) => void }

export function emailFooter(t: { dealerName: string; postalAddress: string | null; unsubscribeUrl: string }): string {
  return `\n\n--\n${t.dealerName}${t.postalAddress ? `\n${t.postalAddress}` : ''}\nUnsubscribe: ${t.unsubscribeUrl}`;
}

export function createDispatcher(o: DispatcherOptions): Dispatcher {
  const now = o.now ?? (() => new Date());

  async function deliver(dealerId: string, provider: string, key: string, draftId: string | null, msg: OutboundMessage, contactId: string | null): Promise<DispatchResult> {
    const adapter = o.registry.get(provider);
    if (!adapter || !adapter.channels.includes(msg.channel)) return { ok: false, error: 'provider_not_configured', retryable: false, detail: provider };
    const claim = (await o.rpc<{ decision: string; provider_message_id: string | null }[]>('claim_send_attempt', {
      p_dealer_id: dealerId, p_key: key, p_provider: provider, p_draft_id: draftId, p_idempotent_provider: adapter.idempotentRetries, p_now: now().toISOString(),
    }))[0];
    if (claim?.decision === 'already_sent') return { ok: true, providerMessageId: claim.provider_message_id ?? '', deduped: true };
    if (claim?.decision === 'in_flight') return { ok: false, error: 'send_in_flight', retryable: true };
    if (claim?.decision === 'unknown') return { ok: false, error: 'send_outcome_unknown', retryable: false, detail: 'a previous attempt may have been delivered; a person must check' };
    let r: SendResult;
    try {
      r = await adapter.send(msg);
    } catch (e) {
      if (e instanceof NetworkError && !adapter.idempotentRetries) {
        o.log?.('send_outcome_unknown', { key, provider });          // attempt stays 'pending' -> 'unknown' on any retry
        return { ok: false, error: 'send_outcome_unknown', retryable: false, detail: e.message };
      }
      r = { ok: false, code: e instanceof NetworkError ? 'network_error' : 'adapter_error', error: (e as Error).message.slice(0, 200), retryable: e instanceof NetworkError };
    }
    await o.rpc('complete_send_attempt', {
      p_dealer_id: dealerId, p_key: key, p_ok: r.ok, p_provider_message_id: r.ok ? r.providerMessageId : null, p_error_code: r.ok ? null : r.code, p_now: now().toISOString(),
    });
    if (r.ok) return { ok: true, providerMessageId: r.providerMessageId };
    if (r.code === 'recipient_opted_out' && contactId) {
      await o.rpc('record_opt_out', { p_dealer_id: dealerId, p_contact_id: contactId, p_channel: msg.channel, p_source: 'sms_keyword',
        p_evidence: { carrier_error: r.providerCode ?? null }, p_note: 'carrier-level opt-out reported on send' }).catch(() => undefined);
    }
    return { ok: false, error: r.code, retryable: r.retryable, detail: r.error };
  }

  return {
    async send(r) {
      const t = await o.rpc<SendTargetRow | null>('get_send_target', { p_number_id: r.numberId, p_contact_id: r.contactId, p_now: now().toISOString() });
      if (!t) return { ok: false, error: 'target_not_found', retryable: false };
      if (!['active', 'paused'].includes(t.number.status)) return { ok: false, error: 'number_unavailable', retryable: false, detail: t.number.status };
      const ch = t.number.channel;
      const to = ch === 'email' ? t.contact.email : t.contact.phone_e164;
      if (!to) return { ok: false, error: 'no_address', retryable: false };
      const msg: OutboundMessage = { channel: ch, to, from: { address: t.number.address, config: t.number.config ?? {} }, body: r.body, idempotencyKey: r.idempotencyKey };
      if (ch === 'whatsapp') {
        if (r.template) {
          // last line of defence: approved, right category for the purpose, and (marketing) opt-out wording present
          const gate = await o.rpc<{ allowed: boolean; code?: string; flags?: string[] }>('check_template_send', { p_number_id: r.numberId, p_name: r.template.name, p_language: r.template.language, p_purpose: r.purpose });
          if (!gate.allowed) return { ok: false, error: gate.code ?? 'template_blocked', retryable: false, detail: gate.flags?.join(',') };
          msg.template = r.template;
        }
        else if (!t.whatsapp_window_open) return { ok: false, error: 'whatsapp_window_closed', retryable: false, detail: 'more than 24 h since the customer wrote; an approved template is required' };
      }
      if (ch === 'email') {
        if (t.email_suppressed) return { ok: false, error: 'email_suppressed', retryable: false, detail: 'address is on the suppression list (bounced)' };
        if (r.purpose === 'marketing' && !t.postal_address) return { ok: false, error: 'can_spam_address_missing', retryable: false, detail: 'set dealers.postal_address' };
        if (!o.unsubscribeBaseUrl) return { ok: false, error: 'unsubscribe_url_missing', retryable: false, detail: 'set UNSUBSCRIBE_BASE_URL' };
        const token = await o.rpc<string>('create_unsubscribe_token', { p_dealer_id: t.dealer_id, p_contact_id: t.contact.id, p_channel: 'email' });
        const url = `${o.unsubscribeBaseUrl.replace(/\/$/, '')}?t=${encodeURIComponent(token)}`;
        msg.body = r.body + emailFooter({ dealerName: t.dealer_name, postalAddress: t.postal_address, unsubscribeUrl: url });
        msg.email = { subject: r.subject ?? `A message from ${t.dealer_name}`, fromName: t.number.config?.from_name ?? t.dealer_name, replyTo: t.number.config?.reply_to ?? null, listUnsubscribeUrl: url };
      }
      return deliver(t.dealer_id, t.number.provider, r.idempotencyKey, r.draftId ?? null, msg, t.contact.id);
    },
    async sendRaw(r) {
      const msg: OutboundMessage = { channel: r.number.channel, to: r.to, from: { address: r.number.address, config: r.number.config ?? {} }, body: r.body, idempotencyKey: r.idempotencyKey };
      if (r.number.channel === 'email') return { ok: false, error: 'staff_email_reply_unsupported', retryable: false };
      return deliver(r.dealerId, r.number.provider, r.idempotencyKey, null, msg, null);
    },
  };
}
