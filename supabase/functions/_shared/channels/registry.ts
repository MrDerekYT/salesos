/**
 * Adapter registry: channel_numbers.provider -> adapter. Built once per Edge Function invocation from env vars.
 * A provider with no credentials is simply absent, so sends fail cleanly with provider_not_configured (reservation released).
 */
import type { ChannelAdapter, FetchLike, ProviderName } from './types.ts';
import { twilioAdapter } from './twilio.ts';
import { whatsappAdapter } from './whatsapp.ts';
import { resendAdapter } from './resend.ts';
import { mockAdapter } from './mock.ts';

export interface AdapterRegistry { get(provider: string): ChannelAdapter | null; providers(): ProviderName[] }
export function createRegistry(adapters: ChannelAdapter[]): AdapterRegistry {
  const m = new Map<string, ChannelAdapter>(adapters.map((a) => [a.provider, a]));
  return { get: (p) => m.get(p) ?? null, providers: () => [...m.keys()] as ProviderName[] };
}

export function functionsUrl(get: (k: string) => string | undefined): string | null {
  const explicit = get('PUBLIC_FUNCTIONS_URL');
  if (explicit) return explicit.replace(/\/$/, '');
  const su = get('SUPABASE_URL');
  return su ? `${su.replace(/\/$/, '')}/functions/v1` : null;
}

export function registryFromEnv(get: (k: string) => string | undefined, f?: FetchLike): AdapterRegistry {
  const list: ChannelAdapter[] = [];
  const fn = functionsUrl(get);
  if (get('TWILIO_ACCOUNT_SID') && get('TWILIO_AUTH_TOKEN')) {
    list.push(twilioAdapter({ accountSid: get('TWILIO_ACCOUNT_SID')!, authToken: get('TWILIO_AUTH_TOKEN')!, statusCallbackUrl: fn ? `${fn}/webhook-twilio?kind=status` : null, fetch: f }));
  }
  if (get('META_ACCESS_TOKEN')) list.push(whatsappAdapter({ accessToken: get('META_ACCESS_TOKEN')!, apiVersion: get('META_API_VERSION') ?? undefined, fetch: f }));
  if (get('RESEND_API_KEY')) list.push(resendAdapter({ apiKey: get('RESEND_API_KEY')!, fetch: f }));
  if (get('SALESOS_ALLOW_MOCK_PROVIDER') === 'true') list.push(mockAdapter());
  return createRegistry(list);
}
