/**
 * Keyword confirmations (STOP / START / HELP) as a durable outbox.
 *   apply_inbound_keyword  -> a keyword_replies row (pending) in the SAME transaction as the opt-out
 *   begin_keyword_reply    -> claims it (attempt N); the webhook tries once inline, the keyword-reply-worker retries
 *   dispatcher.send        -> idempotency key kw:<id>: a retry can never send a second confirmation
 *   finish_keyword_reply   -> sent | pending (backoff) | expired | gave_up | carrier_blocked | unknown (+ inbox item)
 * A STOP confirmation retries only inside the 5-minute window the FCC allows for the one confirmation text, then expires.
 */
import { helpText, stopConfirmationText } from './opt-out.ts';
import type { Channel } from './before-send.ts';
import type { Rpc } from './crm-tools.ts';
import type { Dispatcher } from './channels/dispatch.ts';

export interface ClaimedKeywordReply {
  reply_id: string; kind: 'stop' | 'start' | 'help'; dealer_id: string; contact_id: string; number_id: string | null; channel: Channel;
  attempts: number; dealer_name: string; main_phone: string | null;
}
export interface KeywordReplyDeps { rpc: Rpc; dispatcher: Dispatcher; now(): Date; log?(event: string, data: Record<string, unknown>): void }

export function startConfirmationText(dealerName: string): string {
  return `${dealerName}: You're resubscribed and can text us anytime. Reply STOP to opt out, HELP for help.`;
}
export function keywordReplyText(kind: string, dealerName: string, mainPhone: string | null): string {
  return kind === 'stop' ? stopConfirmationText(dealerName) : kind === 'start' ? startConfirmationText(dealerName) : helpText(dealerName, mainPhone ?? undefined);
}

export type KeywordDelivery = { ok: true; status: 'sent' } | { ok: false; status: string; error: string };

/** Sends one claimed reply and records the outcome. Never throws: a failure is recorded with its retry decision. */
export async function deliverKeywordReply(r: ClaimedKeywordReply, deps: KeywordReplyDeps): Promise<KeywordDelivery> {
  const body = keywordReplyText(r.kind, r.dealer_name, r.main_phone);
  let res: { ok: true; providerMessageId: string } | { ok: false; error: string; retryable: boolean };
  try {
    if (!r.number_id) res = { ok: false, error: 'number_missing', retryable: false };
    else {
      const d = await deps.dispatcher.send({
        numberId: r.number_id, contactId: r.contact_id, body, idempotencyKey: `kw:${r.reply_id}`, purpose: 'transactional', kind: 'system',
        subject: r.channel === 'email' ? `${r.dealer_name}: ${r.kind === 'stop' ? 'you are unsubscribed' : 'your request'}` : null,
      });
      res = d.ok ? { ok: true, providerMessageId: d.providerMessageId } : { ok: false, error: d.error, retryable: d.retryable };
    }
  } catch (e) {
    res = { ok: false, error: `dispatch_exception: ${(e as Error).message.slice(0, 80)}`, retryable: true };
  }
  const status = await deps.rpc<string>('finish_keyword_reply', {
    p_id: r.reply_id, p_ok: res.ok, p_provider_message_id: res.ok ? res.providerMessageId : null, p_error: res.ok ? null : res.error,
    p_retryable: res.ok ? false : res.retryable, p_body: body, p_now: deps.now().toISOString(),
  });
  if (res.ok) return { ok: true, status: 'sent' };
  deps.log?.('keyword_reply_failed', { reply_id: r.reply_id, kind: r.kind, attempt: r.attempts, error: res.error, outcome: status });
  return { ok: false, status, error: res.error };
}

/** The webhook's inline first attempt: claim (respects backoff and the 'sending' lease), then deliver. null = someone else has it. */
export async function attemptKeywordReply(replyId: string, deps: KeywordReplyDeps): Promise<KeywordDelivery | null> {
  const claimed = (await deps.rpc<ClaimedKeywordReply[]>('begin_keyword_reply', { p_id: replyId, p_now: deps.now().toISOString() }))[0];
  return claimed ? deliverKeywordReply(claimed, deps) : null;
}
