/**
 * Twilio Programmable Messaging (SMS). Official REST API, form-encoded.
 *  - Sends through the dealer's Messaging Service (A2P 10DLC / toll-free registered) when provider_config has
 *    messaging_service_sid, else From = the number. StatusCallback points at webhook-twilio?kind=status.
 *  - Twilio has no idempotency key, so idempotentRetries=false: a crash mid-send becomes 'unknown' for a person.
 *  - Error 21610 = the handset replied STOP to this sender at carrier level: we record the opt-out too.
 * Webhooks: X-Twilio-Signature = base64(HMAC-SHA1(auth_token, full_url + sorted(key+value)...)).
 */
import { hmac, safeEqual, toBase64 } from '../crypto.ts';
import { fetchWithTimeout, readJson, type ChannelAdapter, type FetchLike, type OutboundMessage, type SendResult } from './types.ts';

export interface TwilioOptions { accountSid: string; authToken: string; statusCallbackUrl?: string | null; fetch?: FetchLike; baseUrl?: string }

const NON_RETRYABLE: Record<string, string> = {
  '21610': 'recipient_opted_out', '21211': 'invalid_number', '21614': 'not_mobile', '21408': 'region_not_enabled',
  '21606': 'invalid_sender', '21612': 'unreachable_route', '30007': 'carrier_filtered', '21617': 'body_too_long', '20003': 'provider_auth_failed',
};

export function twilioAdapter(o: TwilioOptions): ChannelAdapter {
  const f = o.fetch ?? fetch;
  const base = (o.baseUrl ?? 'https://api.twilio.com').replace(/\/$/, '');
  return {
    provider: 'twilio', channels: ['sms'], idempotentRetries: false,
    async send(m: OutboundMessage): Promise<SendResult> {
      const form = new URLSearchParams();
      form.set('To', m.to);
      form.set('Body', m.body);
      if (m.from.config.messaging_service_sid) form.set('MessagingServiceSid', m.from.config.messaging_service_sid);
      else form.set('From', m.from.address);
      if (o.statusCallbackUrl) form.set('StatusCallback', o.statusCallbackUrl);
      const res = await fetchWithTimeout(f, `${base}/2010-04-01/Accounts/${encodeURIComponent(o.accountSid)}/Messages.json`, {
        method: 'POST',
        headers: { Authorization: `Basic ${btoa(`${o.accountSid}:${o.authToken}`)}`, 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
      });
      const j = await readJson(res);
      if (res.ok && typeof j.sid === 'string') return { ok: true, providerMessageId: j.sid, status: j.status };
      const code = j.code != null ? String(j.code) : undefined;
      const retryable = res.status === 429 || res.status >= 500 || code === '20429';
      const mapped = (code ? NON_RETRYABLE[code] : undefined) ?? (retryable ? 'provider_unavailable' : 'provider_rejected');
      return { ok: false, code: mapped, error: `twilio ${res.status}${code ? ` ${code}` : ''}: ${String(j.message ?? '').slice(0, 160)}`, retryable, providerCode: code };
    },
  };
}

/** Twilio's request validation for form POSTs. `url` must be the exact public URL Twilio called (including query). */
export async function twilioSignature(authToken: string, url: string, params: Record<string, string>): Promise<string> {
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join('');
  return toBase64(await hmac('SHA-1', authToken, data));
}
export async function verifyTwilioSignature(authToken: string, url: string, params: Record<string, string>, signature: string | null): Promise<boolean> {
  if (!signature || !authToken) return false;
  return safeEqual(await twilioSignature(authToken, url, params), signature);
}

export function formToRecord(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of new URLSearchParams(body)) out[k] = v;
  return out;
}

export type TwilioEvent =
  | { kind: 'inbound'; messageSid: string; from: string; to: string; body: string; media: string[]; optOutType: 'STOP' | 'HELP' | 'START' | null }
  | { kind: 'status'; messageSid: string; status: string; errorCode: string | null };

export function parseTwilioEvent(p: Record<string, string>, kindHint: string | null): TwilioEvent | null {
  const sid = p.MessageSid ?? p.SmsSid;
  if (!sid) return null;
  const isStatus = kindHint === 'status' || (!!p.MessageStatus && p.MessageStatus !== 'received' && p.Body === undefined);
  if (isStatus) return { kind: 'status', messageSid: sid, status: (p.MessageStatus ?? p.SmsStatus ?? '').toLowerCase(), errorCode: p.ErrorCode || null };
  const n = Math.min(Number(p.NumMedia ?? 0) || 0, 10);
  const media = Array.from({ length: n }, (_, i) => p[`MediaUrl${i}`]).filter(Boolean);
  const opt = (p.OptOutType ?? '').toUpperCase();
  return { kind: 'inbound', messageSid: sid, from: p.From ?? '', to: p.To ?? '', body: p.Body ?? '', media, optOutType: opt === 'STOP' || opt === 'HELP' || opt === 'START' ? opt : null };
}
