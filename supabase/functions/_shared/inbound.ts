/**
 * The inbound turn pipeline shared by every webhook (DeskcommCRM-style "keywords before AI", original code):
 *   1. resolve the receiving number -> dealer (unknown number => ignored)
 *   2. allow-listed staff sender => CRM-by-text command, reply, done (never threaded as a customer)
 *   3. ingest_inbound_message: contact + open lead + conversation + message (idempotent on the provider id; the
 *      message insert bumps context_version, marks pending AI drafts stale and cancels follow-ups via triggers)
 *   4. STOP/HELP/START/probable-stop detection FIRST (apply_inbound_keyword) - before any model sees the text
 *   5. the one required confirmation (STOP once per opt-out, START once per re-opt-in, HELP at most hourly) is a durable
 *      outbox row (keyword_replies): tried inline once, retried with backoff by keyword-reply-worker, key kw:<id> so it is never sent twice
 *   6. otherwise an agent job (debounced, one lane per lead) + a classification job; kick the runner
 */
import { classifyInbound, type OptOutLevel } from './opt-out.ts';
import { attemptKeywordReply, keywordReplyText, startConfirmationText } from './keyword-replies.ts';
import type { Channel } from './before-send.ts';
import type { Rpc } from './crm-tools.ts';
import { handleStaffText, type StaffDeps } from './staff-commands.ts';
import type { Dispatcher } from './channels/dispatch.ts';
import type { NumberConfig } from './channels/types.ts';

export interface InboundMessage {
  channel: Channel;
  /** our side: E.164 / mailbox, or the WhatsApp phone_number_id */
  to: string;
  from: string;
  body: string;
  providerMessageId: string;
  receivedAt: Date;
  media?: unknown;
  profileName?: string | null;
  /** set when the provider already handled a keyword (Twilio Advanced Opt-Out OptOutType) */
  providerOptOut?: 'STOP' | 'HELP' | 'START' | null;
}
export interface InboundDeps {
  rpc: Rpc;
  dispatcher: Dispatcher;
  staff?: StaffDeps | null;
  now(): Date;
  kickRunner?(): Promise<void>;
  log?(event: string, data: Record<string, unknown>): void;
}
export type InboundOutcome =
  | { status: 'ignored'; reason: string; dealerId?: string }
  | { status: 'staff'; dealerId: string; replied: boolean }
  | { status: 'processed'; dealerId: string; messageId: string; leadId: string; contactId: string; duplicate: boolean; action: string; reply: { kind: string; ok: boolean; error?: string } | null };

interface NumberRow { number_id: string; dealer_id: string; provider: string; config: NumberConfig; dealer_name: string; main_phone: string | null; address: string; channel: Channel }

export { keywordReplyText, startConfirmationText };

export async function processInbound(m: InboundMessage, deps: InboundDeps): Promise<InboundOutcome> {
  const n = (await deps.rpc<NumberRow[]>('resolve_inbound_number', { p_channel: m.channel, p_address: m.to }))[0];
  if (!n) return { status: 'ignored', reason: 'unknown_number' };

  if (deps.staff && m.channel !== 'email') {
    const reply = await handleStaffText({ dealerId: n.dealer_id, channel: m.channel, address: m.from, text: m.body }, deps.staff);
    if (reply !== null) {
      const r = await deps.dispatcher.sendRaw({ dealerId: n.dealer_id, number: { id: n.number_id, channel: n.channel, provider: n.provider, address: n.address, config: n.config ?? {} },
                                                to: m.from, body: reply.slice(0, 900), idempotencyKey: `staff:${m.providerMessageId}` });
      return { status: 'staff', dealerId: n.dealer_id, replied: r.ok };
    }
  }

  const ing = (await deps.rpc<{ message_id: string; dealer_id: string; contact_id: string; lead_id: string; conversation_id: string; duplicate: boolean }[]>('ingest_inbound_message', {
    p_number_id: n.number_id, p_from: m.from, p_body: m.body, p_provider_message_id: m.providerMessageId, p_received_at: m.receivedAt.toISOString(),
    p_media: m.media ?? null, p_first_name: m.profileName?.split(/\s+/)[0] ?? null,
  }))[0];

  const k = classifyInbound(m.body);
  let level: OptOutLevel = k.level;
  const providerHandles = !!m.providerOptOut || (m.channel === 'sms' && !!n.config?.provider_handles_keywords);
  if (m.providerOptOut) level = m.providerOptOut === 'STOP' ? 'stop' : m.providerOptOut === 'START' ? 'start' : 'help';

  const kw = (await deps.rpc<{ action: string; reply_kind: string | null; keyword_reply_id: string | null; consent_event_id: string | null }[]>('apply_inbound_keyword', {
    p_message_id: ing.message_id, p_level: level, p_scope: k.scope, p_matched: k.matched ?? m.providerOptOut ?? null, p_legal_threat: k.legalThreat,
    p_provider_handles_reply: providerHandles, p_now: deps.now().toISOString(),
  }))[0];

  let reply: { kind: string; ok: boolean; error?: string } | null = null;
  if (kw.reply_kind && kw.keyword_reply_id) {
    // first attempt inline; if it fails the row stays in the outbox and keyword-reply-worker retries (never a second send: key kw:<id>)
    const out = await attemptKeywordReply(kw.keyword_reply_id, { rpc: deps.rpc, dispatcher: deps.dispatcher, now: deps.now, log: deps.log });
    if (out) reply = out.ok ? { kind: kw.reply_kind, ok: true } : { kind: kw.reply_kind, ok: false, error: out.error };
  }
  if (kw.action === 'agent') await deps.kickRunner?.().catch(() => undefined);
  return { status: 'processed', dealerId: ing.dealer_id, messageId: ing.message_id, leadId: ing.lead_id, contactId: ing.contact_id, duplicate: ing.duplicate, action: kw.action, reply };
}
