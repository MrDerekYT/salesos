/**
 * webhook-meta: WhatsApp Cloud API webhooks. GET = subscription handshake (hub.verify_token); POST = messages,
 * delivery/read statuses and template status updates, authenticated by X-Hub-Signature-256 over the RAW body.
 */
import { metaVerifyChallenge, parseMetaWebhook, verifyMetaSignature } from '../_shared/channels/whatsapp.ts';
import { processInbound } from '../_shared/inbound.ts';
import { withEventLog, type WebhookDeps } from '../_shared/webhook.ts';

export interface MetaWebhookDeps extends WebhookDeps { appSecret: string; verifyToken: string }

export async function handleMetaWebhook(req: Request, deps: MetaWebhookDeps): Promise<Response> {
  if (req.method === 'GET') {
    const c = metaVerifyChallenge(new URL(req.url), deps.verifyToken);
    return c ? new Response(c, { status: 200, headers: { 'Content-Type': 'text/plain' } }) : new Response('forbidden', { status: 403 });
  }
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const raw = await req.text();
  if (!(await verifyMetaSignature(deps.appSecret, raw, req.headers.get('x-hub-signature-256')))) return new Response('invalid signature', { status: 403 });
  let json: unknown;
  try { json = JSON.parse(raw); } catch { return new Response('bad json', { status: 400 }); }
  const now = deps.now();
  let failed = 0;
  for (const ev of parseMetaWebhook(json)) {
    try {
      if (ev.kind === 'inbound') {
        await withEventLog(deps.rpc, 'meta_cloud', ev.id, 'inbound', ev, now, async () => {
          const r = await processInbound({ channel: 'whatsapp', to: ev.phoneNumberId, from: ev.from, body: ev.body, providerMessageId: ev.id, receivedAt: ev.timestamp,
                                           profileName: ev.profileName, media: ev.type !== 'text' ? { type: ev.type } : null }, deps);
          return { status: r.status === 'ignored' ? 'ignored' : 'processed', dealerId: r.dealerId ?? null };
        });
      } else if (ev.kind === 'status') {
        await withEventLog(deps.rpc, 'meta_cloud', `${ev.id}:${ev.status}`, 'status', ev, now, async () => {
          const r = (await deps.rpc<{ message_id: string | null }[]>('apply_message_status', { p_channel: 'whatsapp', p_provider_message_id: ev.id, p_status: ev.status, p_error_code: ev.errorCode, p_at: ev.timestamp.toISOString() }))[0];
          return { status: r?.message_id ? 'processed' : 'ignored' };
        });
      } else {
        await withEventLog(deps.rpc, 'meta_cloud', `tpl:${ev.templateId ?? ev.name}:${ev.event}:${ev.reason ?? ''}`, 'template_status', ev, now, async () => {
          const n = await deps.rpc<number>('apply_template_status', { p_waba_id: ev.wabaId, p_provider_template_id: ev.templateId, p_name: ev.name, p_language: ev.language, p_status: ev.event, p_reason: ev.reason, p_now: now.toISOString() });
          return { status: n > 0 ? 'processed' : 'ignored' };
        });
      }
    } catch (e) {
      failed++;
      deps.log?.('meta_webhook_error', { error: (e as Error).message });
    }
  }
  return failed ? new Response('partial failure', { status: 500 }) : new Response('ok', { status: 200 });
}
