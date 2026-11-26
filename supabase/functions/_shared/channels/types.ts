/**
 * One interface for every customer channel. Adapters are thin: they translate an OutboundMessage into the provider's
 * official API call and map the provider's errors into { code, retryable }. Compliance never lives here: by the time
 * an adapter runs, the before-send chain and can_send(commit) have already approved the exact body.
 * Secrets come from env vars only; channel_numbers.provider_config holds non-secret ids.
 */
import type { Channel } from '../before-send.ts';

export type ProviderName = 'twilio' | 'meta_cloud' | 'resend' | 'mock';
export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

export interface NumberConfig {
  messaging_service_sid?: string;          // twilio
  provider_handles_keywords?: boolean;     // twilio Advanced Opt-Out answers STOP/HELP itself
  phone_number_id?: string;                // meta_cloud
  waba_id?: string;                        // meta_cloud
  from_name?: string;                      // resend
  reply_to?: string;                       // resend
}

export interface OutboundMessage {
  channel: Channel;
  to: string;                              // E.164 for sms/whatsapp, mailbox for email
  from: { address: string; config: NumberConfig };
  body: string;
  idempotencyKey: string;
  template?: { name: string; language: string; params: string[] };     // WhatsApp outside the 24 h window
  email?: { subject: string; fromName: string; replyTo?: string | null; listUnsubscribeUrl: string; listUnsubscribeMailto?: string | null };
}

export type SendResult =
  | { ok: true; providerMessageId: string; status?: string }
  | { ok: false; code: string; error: string; retryable: boolean; providerCode?: string };

export interface ChannelAdapter {
  provider: ProviderName;
  channels: readonly Channel[];
  /** true when the provider dedupes on our idempotency key, so a crashed attempt can be retried with the same key */
  idempotentRetries: boolean;
  send(m: OutboundMessage): Promise<SendResult>;
}

/** Timeout + network error mapping shared by the adapters. A thrown fetch means "outcome unknown" to the caller. */
export class NetworkError extends Error {}
export async function fetchWithTimeout(f: FetchLike, url: string, init: RequestInit, ms = 10_000): Promise<Response> {
  try {
    return await f(url, { ...init, signal: AbortSignal.timeout(ms) });
  } catch (e) {
    throw new NetworkError(`network: ${(e as Error).message}`.slice(0, 200));
  }
}
export async function readJson(res: Response): Promise<Record<string, any>> {
  const t = await res.text();
  try { return t ? JSON.parse(t) : {}; } catch { return { raw: t.slice(0, 200) }; }
}
