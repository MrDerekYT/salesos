/**
 * Meta WhatsApp Business Cloud API (official Graph API; no unofficial web clients: those get numbers banned).
 *  - Inside the 24 h customer-service window: free-form "session" text.
 *  - Outside it: an APPROVED template only (MARKETING category for marketing purposes, else UTILITY). The dispatcher
 *    picks the template; the rendered template text is what the gates checked.
 *  - Template status is synced both ways: pull (fetchTemplates -> upsert_message_templates, hourly) and push
 *    (message_template_status_update webhook -> apply_template_status).
 * Webhooks: X-Hub-Signature-256 = "sha256=" + hex(HMAC-SHA256(app_secret, raw body)); GET hub.verify_token handshake.
 */
import { hmac, safeEqual, toHex } from '../crypto.ts';
import { fetchWithTimeout, readJson, type ChannelAdapter, type FetchLike, type OutboundMessage, type SendResult } from './types.ts';

export interface WhatsAppOptions { accessToken: string; apiVersion?: string; fetch?: FetchLike; baseUrl?: string }
const graph = (o: WhatsAppOptions) => `${(o.baseUrl ?? 'https://graph.facebook.com').replace(/\/$/, '')}/${o.apiVersion ?? 'v21.0'}`;

const ERRORS: Record<string, { code: string; retryable: boolean }> = {
  '131047': { code: 'whatsapp_window_closed', retryable: false },     // re-engagement: >24 h since the customer wrote
  '131026': { code: 'undeliverable', retryable: false },
  '131050': { code: 'marketing_opt_out', retryable: false },          // user stopped marketing messages
  '131051': { code: 'unsupported_message', retryable: false },
  '132000': { code: 'template_param_mismatch', retryable: false },
  '132001': { code: 'template_missing', retryable: false },
  '132015': { code: 'template_paused', retryable: false },
  '132016': { code: 'template_disabled', retryable: false },
  '130429': { code: 'rate_limited', retryable: true },
  '131056': { code: 'pair_rate_limited', retryable: true },
  '131048': { code: 'spam_rate_limited', retryable: true },
  '190': { code: 'provider_auth_failed', retryable: false },
  '100': { code: 'provider_rejected', retryable: false },
};

export const waTo = (e164: string) => e164.replace(/^\+/, '');

export function whatsappAdapter(o: WhatsAppOptions): ChannelAdapter {
  const f = o.fetch ?? fetch;
  return {
    provider: 'meta_cloud', channels: ['whatsapp'], idempotentRetries: false,
    async send(m: OutboundMessage): Promise<SendResult> {
      const phoneId = m.from.config.phone_number_id;
      if (!phoneId) return { ok: false, code: 'provider_config_missing', error: 'channel_numbers.provider_config.phone_number_id is not set', retryable: false };
      const payload = m.template
        ? { messaging_product: 'whatsapp', recipient_type: 'individual', to: waTo(m.to), type: 'template',
            template: { name: m.template.name, language: { code: m.template.language },
                        components: m.template.params.length ? [{ type: 'body', parameters: m.template.params.map((t) => ({ type: 'text', text: t })) }] : [] } }
        : { messaging_product: 'whatsapp', recipient_type: 'individual', to: waTo(m.to), type: 'text', text: { body: m.body, preview_url: false } };
      const res = await fetchWithTimeout(f, `${graph(o)}/${encodeURIComponent(phoneId)}/messages`, {
        method: 'POST', headers: { Authorization: `Bearer ${o.accessToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
      });
      const j = await readJson(res);
      const id = j.messages?.[0]?.id;
      if (res.ok && typeof id === 'string') return { ok: true, providerMessageId: id, status: 'accepted' };
      const pc = j.error?.code != null ? String(j.error.code) : undefined;
      const m2 = (pc ? ERRORS[pc] : undefined) ?? { code: res.status === 429 || res.status >= 500 ? 'provider_unavailable' : 'provider_rejected', retryable: res.status === 429 || res.status >= 500 };
      return { ok: false, code: m2.code, error: `meta ${res.status}${pc ? ` ${pc}` : ''}: ${String(j.error?.message ?? '').slice(0, 160)}`, retryable: m2.retryable, providerCode: pc };
    },
  };
}

export async function verifyMetaSignature(appSecret: string, rawBody: string, header: string | null): Promise<boolean> {
  if (!header || !appSecret || !header.startsWith('sha256=')) return false;
  return safeEqual(`sha256=${toHex(await hmac('SHA-256', appSecret, rawBody))}`, header);
}
export function metaVerifyChallenge(url: URL, verifyToken: string): string | null {
  const mode = url.searchParams.get('hub.mode'), token = url.searchParams.get('hub.verify_token'), challenge = url.searchParams.get('hub.challenge');
  if (mode === 'subscribe' && verifyToken && token && safeEqual(token, verifyToken) && challenge) return challenge;
  return null;
}

export type MetaEvent =
  | { kind: 'inbound'; phoneNumberId: string; from: string; id: string; timestamp: Date; body: string; type: string; profileName: string | null }
  | { kind: 'status'; phoneNumberId: string; id: string; status: string; timestamp: Date; errorCode: string | null }
  | { kind: 'template'; wabaId: string; templateId: string | null; name: string; language: string | null; event: string; reason: string | null };

const tsDate = (t: unknown) => new Date((Number(t) || Date.now() / 1000) * 1000);

/** Flattens a Cloud API webhook into events. Unknown shapes are skipped, never thrown on. */
export function parseMetaWebhook(j: any): MetaEvent[] {
  const out: MetaEvent[] = [];
  if (j?.object !== 'whatsapp_business_account') return out;
  for (const entry of j.entry ?? []) {
    for (const ch of entry.changes ?? []) {
      const v = ch.value ?? {};
      if (ch.field === 'messages') {
        const phoneNumberId = String(v.metadata?.phone_number_id ?? '');
        const names = new Map<string, string>((v.contacts ?? []).map((c: any) => [String(c.wa_id), String(c.profile?.name ?? '')]));
        for (const m of v.messages ?? []) {
          const body = m.type === 'text' ? m.text?.body : m.type === 'button' ? m.button?.text
            : m.type === 'interactive' ? (m.interactive?.button_reply?.title ?? m.interactive?.list_reply?.title) : m.caption ?? (m[m.type]?.caption ?? '');
          const from = String(m.from ?? '');
          out.push({ kind: 'inbound', phoneNumberId, from: from.startsWith('+') ? from : `+${from}`, id: String(m.id), timestamp: tsDate(m.timestamp),
                     body: String(body ?? ''), type: String(m.type ?? 'unknown'), profileName: names.get(from) || null });
        }
        for (const s of v.statuses ?? []) {
          out.push({ kind: 'status', phoneNumberId, id: String(s.id), status: String(s.status), timestamp: tsDate(s.timestamp), errorCode: s.errors?.[0]?.code != null ? String(s.errors[0].code) : null });
        }
      } else if (ch.field === 'message_template_status_update') {
        out.push({ kind: 'template', wabaId: String(entry.id), templateId: v.message_template_id != null ? String(v.message_template_id) : null,
                   name: String(v.message_template_name ?? ''), language: v.message_template_language ?? null, event: String(v.event ?? ''), reason: v.reason ?? null });
      }
    }
  }
  return out;
}

export interface TemplateRow { id: string; name: string; language: string; category: string; status: string; body_text: string | null; param_count: number; rejected_reason: string | null; has_opt_out_button: boolean }
/** A quick-reply button such as "Stop promotions" / "Unsubscribe" counts as opt-out wording (Meta's marketing opt-out pattern). */
export function hasOptOutButton(components: unknown): boolean {
  const btns = (Array.isArray(components) ? components : []).filter((c: any) => c?.type === 'BUTTONS').flatMap((c: any) => c.buttons ?? []);
  return btns.some((b: any) => b?.type === 'QUICK_REPLY' && /\b(stop|unsubscribe|opt[\s-]?out|no more|end)\b/i.test(String(b?.text ?? '')));
}

export async function fetchTemplates(o: WhatsAppOptions, wabaId: string, maxPages = 10): Promise<TemplateRow[]> {
  const f = o.fetch ?? fetch;
  const rows: TemplateRow[] = [];
  let url: string | null = `${graph(o)}/${encodeURIComponent(wabaId)}/message_templates?fields=id,name,language,status,category,components,rejected_reason&limit=100`;
  for (let page = 0; url && page < maxPages; page++) {
    const res = await fetchWithTimeout(f, url, { method: 'GET', headers: { Authorization: `Bearer ${o.accessToken}` } });
    const j = await readJson(res);
    if (!res.ok) throw new Error(`meta templates ${res.status}: ${String(j.error?.message ?? '').slice(0, 160)}`);
    for (const t of j.data ?? []) {
      const body = (t.components ?? []).find((c: any) => c.type === 'BODY')?.text ?? null;
      rows.push({ id: String(t.id), name: String(t.name), language: String(t.language), category: String(t.category ?? '').toUpperCase(), status: String(t.status ?? '').toUpperCase(),
                  body_text: body, param_count: body ? new Set(body.match(/\{\{\d+\}\}/g) ?? []).size : 0, rejected_reason: t.rejected_reason ?? null, has_opt_out_button: hasOptOutButton(t.components) });
    }
    url = typeof j.paging?.next === 'string' ? j.paging.next : null;
  }
  return rows;
}

/** {{1}}..{{n}} substitution. Missing params make the template unusable (returns null) rather than sending "{{2}}". */
export function renderTemplate(body: string, params: string[]): string | null {
  let missing = false;
  const out = body.replace(/\{\{(\d+)\}\}/g, (_, n) => { const v = params[Number(n) - 1]; if (v == null || v === '') missing = true; return v ?? ''; });
  return missing ? null : out;
}
