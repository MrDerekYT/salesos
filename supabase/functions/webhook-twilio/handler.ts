/**
 * webhook-twilio: inbound SMS (Messaging Service "A message comes in" URL) and status callbacks (?kind=status).
 * Deploy with verify_jwt=false: authenticity comes from X-Twilio-Signature, checked against the PUBLIC url Twilio called.
 */
import { formToRecord, parseTwilioEvent, verifyTwilioSignature } from '../_shared/channels/twilio.ts';
import { processInbound } from '../_shared/inbound.ts';
import { withEventLog, type WebhookDeps } from '../_shared/webhook.ts';

export interface TwilioWebhookDeps extends WebhookDeps { authToken: string; publicUrl: (req: Request) => string }
const TWIML_EMPTY = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>';

export async function handleTwilioWebhook(req: Request, deps: TwilioWebhookDeps): Promise<Response> {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const raw = await req.text();
  const params = formToRecord(raw);
  const url = deps.publicUrl(req);
  if (!(await verifyTwilioSignature(deps.authToken, url, params, req.headers.get('x-twilio-signature')))) return new Response('invalid signature', { status: 403 });
  const ev = parseTwilioEvent(params, new URL(url).searchParams.get('kind'));
  if (!ev) return new Response('bad request', { status: 400 });
  const now = deps.now();
  try {
    if (ev.kind === 'status') {
      await withEventLog(deps.rpc, 'twilio', `${ev.messageSid}:${ev.status}`, 'status', params, now, async () => {
        const r = (await deps.rpc<{ message_id: string | null; applied: boolean }[]>('apply_message_status', { p_channel: 'sms', p_provider_message_id: ev.messageSid, p_status: ev.status, p_error_code: ev.errorCode, p_at: now.toISOString() }))[0];
        return { status: r?.message_id ? 'processed' : 'ignored' };
      });
      return new Response(null, { status: 204 });
    }
    await withEventLog(deps.rpc, 'twilio', ev.messageSid, 'inbound', params, now, async () => {
      const r = await processInbound({ channel: 'sms', to: ev.to, from: ev.from, body: ev.body, providerMessageId: ev.messageSid, receivedAt: now,
                                       media: ev.media.length ? ev.media : null, providerOptOut: ev.optOutType }, deps);
      return { status: r.status === 'ignored' ? 'ignored' : 'processed', dealerId: r.dealerId ?? null };
    });
    return new Response(TWIML_EMPTY, { status: 200, headers: { 'Content-Type': 'text/xml' } });
  } catch (e) {
    deps.log?.('twilio_webhook_error', { error: (e as Error).message });
    return new Response('error', { status: 500 });
  }
}
