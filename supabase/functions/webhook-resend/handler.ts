/**
 * webhook-resend: Resend events via Svix signatures. Delivery/bounce/complaint update the message (a complaint is an
 * email opt-out); email.received (inbound routing) runs the same inbound pipeline as SMS/WhatsApp.
 */
import { fetchReceivedEmail, parseResendEvent, verifySvix, type ResendOptions } from '../_shared/channels/resend.ts';
import { processInbound } from '../_shared/inbound.ts';
import { withEventLog, type WebhookDeps } from '../_shared/webhook.ts';

export interface ResendWebhookDeps extends WebhookDeps {
  webhookSecret: string;
  /** Resend API access for fetching inbound bodies (the email.received webhook carries no text). Without it the subject is used. */
  api?: ResendOptions | null;
}

export async function handleResendWebhook(req: Request, deps: ResendWebhookDeps): Promise<Response> {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const raw = await req.text();
  const h = { id: req.headers.get('svix-id'), timestamp: req.headers.get('svix-timestamp'), signature: req.headers.get('svix-signature') };
  const now = deps.now();
  if (!(await verifySvix(deps.webhookSecret, h, raw, now))) return new Response('invalid signature', { status: 403 });
  let json: any;
  try { json = JSON.parse(raw); } catch { return new Response('bad json', { status: 400 }); }
  const ev = parseResendEvent(json);
  try {
    await withEventLog(deps.rpc, 'resend', h.id!, String(json?.type ?? 'unknown'), json, now, async () => {
      if (ev.kind === 'ignored') return { status: 'ignored' };
      if (ev.kind === 'status') {
        const r = (await deps.rpc<{ message_id: string | null }[]>('apply_message_status', { p_channel: 'email', p_provider_message_id: ev.emailId, p_status: ev.status, p_error_code: ev.error, p_at: now.toISOString() }))[0];
        let bounced = false;
        if (ev.bounce) {
          // hard => suppressed at once; soft => counted toward the dealer's threshold (record_email_bounce is idempotent on the svix id)
          const b = (await deps.rpc<{ recorded: boolean; suppressed: boolean; reason: string | null }[]>('record_email_bounce', {
            p_provider_message_id: ev.emailId, p_kind: ev.bounce.kind, p_email: ev.bounce.to, p_diagnostic: ev.bounce.detail, p_provider_event_id: h.id, p_now: now.toISOString() }))[0];
          bounced = !!b?.recorded;
          if (b?.suppressed) deps.log?.('email_suppressed', { email_id: ev.emailId, reason: b.reason });
        }
        return { status: r?.message_id || bounced ? 'processed' : 'ignored' };
      }
      let body = ev.text ?? '';
      let media: unknown = null;
      if (!body) {
        let got = null;
        if (deps.api) got = await fetchReceivedEmail(deps.api, ev.emailId);       // throws on transient errors => 500 => Resend retries
        else deps.log?.('inbound_body_not_fetched', { email_id: ev.emailId, reason: 'RESEND_API_KEY not set' });
        if (got && got.text) { body = got.text; media = { email: { body_source: got.source, auth: got.authentication, attachments: got.attachments } }; }
        else { body = ev.subject; media = { email: { body_source: 'subject_only' } }; deps.log?.('inbound_body_unavailable', { email_id: ev.emailId }); }
      }
      const r = await processInbound({ channel: 'email', to: ev.to, from: ev.from, body: body || ev.subject, providerMessageId: ev.emailId, receivedAt: now, profileName: ev.fromName, media }, deps);
      return { status: r.status === 'ignored' ? 'ignored' : 'processed', dealerId: r.dealerId ?? null };
    });
    return new Response('ok', { status: 200 });
  } catch (e) {
    deps.log?.('resend_webhook_error', { error: (e as Error).message });
    return new Response('error', { status: 500 });
  }
}
