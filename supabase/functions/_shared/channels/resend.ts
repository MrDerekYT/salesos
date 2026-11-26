/**
 * Resend (email). POST /emails with an Idempotency-Key header (Resend dedupes for 24 h), so idempotentRetries=true.
 *  - Every email carries RFC 8058 one-click unsubscribe: List-Unsubscribe: <https://.../unsubscribe?t=TOKEN>, <mailto:...>
 *    and List-Unsubscribe-Post: List-Unsubscribe=One-Click (Gmail/Yahoo bulk-sender rules), plus a visible link.
 *  - Commercial (marketing) email also needs the dealer's postal address (CAN-SPAM); the dispatcher refuses without it.
 * Webhooks are signed with Svix: base64(HMAC-SHA256(base64decode(whsec_...), `${id}.${timestamp}.${body}`)), "v1,<sig>".
 */
import { fromBase64, hmac, safeEqual, toBase64 } from '../crypto.ts';
import { fetchWithTimeout, readJson, type ChannelAdapter, type FetchLike, type OutboundMessage, type SendResult } from './types.ts';

export interface ResendOptions { apiKey: string; fetch?: FetchLike; baseUrl?: string }

export function listUnsubscribeHeaders(url: string, mailto?: string | null): Record<string, string> {
  return { 'List-Unsubscribe': mailto ? `<${url}>, <mailto:${mailto}?subject=unsubscribe>` : `<${url}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' };
}

export function resendAdapter(o: ResendOptions): ChannelAdapter {
  const f = o.fetch ?? fetch;
  const base = (o.baseUrl ?? 'https://api.resend.com').replace(/\/$/, '');
  return {
    provider: 'resend', channels: ['email'], idempotentRetries: true,
    async send(m: OutboundMessage): Promise<SendResult> {
      if (!m.email) return { ok: false, code: 'email_meta_missing', error: 'subject/unsubscribe missing', retryable: false };
      const fromName = m.email.fromName.replace(/[<>"\r\n]/g, '').slice(0, 80);
      const res = await fetchWithTimeout(f, `${base}/emails`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${o.apiKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': m.idempotencyKey.slice(0, 256) },
        body: JSON.stringify({
          from: `${fromName} <${m.from.address}>`, to: [m.to], subject: m.email.subject.slice(0, 200), text: m.body,
          ...(m.email.replyTo ? { reply_to: m.email.replyTo } : {}),
          headers: listUnsubscribeHeaders(m.email.listUnsubscribeUrl, m.email.listUnsubscribeMailto),
        }),
      });
      const j = await readJson(res);
      if (res.ok && typeof j.id === 'string') return { ok: true, providerMessageId: j.id, status: 'sent' };
      const retryable = res.status === 429 || res.status >= 500 || res.status === 409;   // 409: same key still in flight
      const code = res.status === 401 || res.status === 403 ? 'provider_auth_failed' : res.status === 422 ? 'invalid_email' : retryable ? 'provider_unavailable' : 'provider_rejected';
      return { ok: false, code, error: `resend ${res.status}: ${String(j.message ?? j.name ?? '').slice(0, 160)}`, retryable, providerCode: String(res.status) };
    },
  };
}

export async function svixSignature(secret: string, id: string, timestamp: string, body: string): Promise<string> {
  const key = fromBase64(secret.startsWith('whsec_') ? secret.slice(6) : secret);
  return `v1,${toBase64(await hmac('SHA-256', key, `${id}.${timestamp}.${body}`))}`;
}
export async function verifySvix(secret: string, h: { id: string | null; timestamp: string | null; signature: string | null }, body: string, now: Date, toleranceSec = 300): Promise<boolean> {
  if (!secret || !h.id || !h.timestamp || !h.signature) return false;
  const ts = Number(h.timestamp);
  if (!Number.isFinite(ts) || Math.abs(now.getTime() / 1000 - ts) > toleranceSec) return false;
  const expected = await svixSignature(secret, h.id, h.timestamp, body);
  return h.signature.split(' ').some((s) => safeEqual(s, expected));
}

export interface BounceInfo { kind: 'hard' | 'soft'; detail: string; to: string | null }
export type ResendEvent =
  | { kind: 'status'; emailId: string; status: 'sent' | 'delivered' | 'failed' | 'complained'; error: string | null; bounce?: BounceInfo }
  | { kind: 'inbound'; emailId: string; from: string; fromName: string | null; to: string; subject: string; text: string | null; html: boolean }
  | { kind: 'ignored'; type: string };

export function parseAddress(s: string): { email: string; name: string | null } {
  const m = /^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/.exec(s);
  return m ? { email: m[2].trim().toLowerCase(), name: m[1].trim() || null } : { email: s.trim().toLowerCase(), name: null };
}
/** Keep only the new part of a reply (drop quoted history), so "STOP" at the top is not drowned by our own footer. */
export function stripQuotedReply(text: string): string {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const out: string[] = [];
  for (const l of lines) {
    if (/^\s*>/.test(l) || /^On .{4,120} wrote:\s*$/.test(l) || /^-{2,}\s*Original Message/i.test(l) || /^From: /.test(l)) break;
    out.push(l);
  }
  return out.join('\n').trim();
}

/** Resend bounce.type: Permanent => hard; Transient / Undetermined => soft (counted toward the dealer's threshold). Unknown => hard (Resend only emits email.bounced for permanent rejections). */
export function bounceFrom(d: any): BounceInfo {
  const t = String(d?.bounce?.type ?? 'Permanent').toLowerCase();
  const to = Array.isArray(d?.to) ? d.to[0] : d?.to;
  return {
    kind: t === 'transient' || t === 'undetermined' ? 'soft' : 'hard',
    detail: [d?.bounce?.type, d?.bounce?.subType, d?.bounce?.message].filter(Boolean).join(': ').slice(0, 300) || 'bounce',
    to: typeof to === 'string' ? parseAddress(to).email : null,
  };
}

export function parseResendEvent(j: any): ResendEvent {
  const t = String(j?.type ?? '');
  const d = j?.data ?? {};
  const id = String(d.email_id ?? d.id ?? '');
  switch (t) {
    case 'email.sent': return { kind: 'status', emailId: id, status: 'sent', error: null };
    case 'email.delivered': return { kind: 'status', emailId: id, status: 'delivered', error: null };
    case 'email.bounced': return { kind: 'status', emailId: id, status: 'failed', error: 'bounce', bounce: bounceFrom(d) };
    case 'email.suppressed': return { kind: 'status', emailId: id, status: 'failed', error: 'suppressed', bounce: { ...bounceFrom({ ...d, bounce: undefined }), kind: 'hard', detail: 'suppressed by the provider' } };
    case 'email.failed': return { kind: 'status', emailId: id, status: 'failed', error: 'failed' };
    case 'email.complained': return { kind: 'status', emailId: id, status: 'complained', error: null };
    case 'email.received': {
      const from = parseAddress(String(d.from ?? ''));
      const to = parseAddress(String(Array.isArray(d.to) ? d.to[0] : d.to ?? ''));
      const text = typeof d.text === 'string' && d.text.trim() !== '' ? stripQuotedReply(d.text) : null;
      return { kind: 'inbound', emailId: id, from: from.email, fromName: from.name, to: to.email, subject: String(d.subject ?? ''), text, html: typeof d.html === 'string' && d.html !== '' };
    }
    default: return { kind: 'ignored', type: t };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Inbound bodies. The email.received webhook carries metadata only (no text/html); the body is fetched from
// GET /emails/receiving/{id}. Transient failures (network, 429, 5xx, auth) THROW so the webhook returns 500 and
// Resend/Svix retries it; a permanent miss (404/410) returns null and the caller falls back to the subject line.
export interface ReceivedEmail { text: string; authentication: { spf?: string; dkim?: string; dmarc?: string } | null; attachments: number; source: 'text' | 'html' | 'empty' }

export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>|<\/(p|div|li|tr|h[1-6]|blockquote)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ').replace(/&amp;/gi, '&').replace(/&lt;/gi, '<').replace(/&gt;/gi, '>').replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'")
    .replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

export async function fetchReceivedEmail(o: ResendOptions, emailId: string): Promise<ReceivedEmail | null> {
  const f = o.fetch ?? fetch;
  const base = (o.baseUrl ?? 'https://api.resend.com').replace(/\/$/, '');
  const res = await fetchWithTimeout(f, `${base}/emails/receiving/${encodeURIComponent(emailId)}?html_format=cid`, { method: 'GET', headers: { Authorization: `Bearer ${o.apiKey}` } });
  if (res.status === 404 || res.status === 410) return null;
  const j = await readJson(res);
  if (!res.ok) throw new Error(`resend receiving ${res.status}: ${String(j.message ?? j.name ?? '').slice(0, 120)}`);
  const plain = typeof j.text === 'string' ? j.text.trim() : '';
  const html = typeof j.html === 'string' ? htmlToText(j.html) : '';
  const raw = plain || html;
  const text = stripQuotedReply(raw).slice(0, 4000);
  return {
    text, source: plain ? 'text' : html ? 'html' : 'empty',
    authentication: j.authentication && typeof j.authentication === 'object' ? { spf: j.authentication.spf, dkim: j.authentication.dkim, dmarc: j.authentication.dmarc } : null,
    attachments: Array.isArray(j.attachments) ? j.attachments.length : 0,
  };
}
