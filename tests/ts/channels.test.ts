/** Channel adapters against mocked HTTP only (no credentials, no network): request shape, error mapping, signatures. */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { twilioAdapter, twilioSignature, verifyTwilioSignature, parseTwilioEvent, formToRecord } from '../../supabase/functions/_shared/channels/twilio.ts';
import { whatsappAdapter, verifyMetaSignature, metaVerifyChallenge, parseMetaWebhook, fetchTemplates, renderTemplate } from '../../supabase/functions/_shared/channels/whatsapp.ts';
import { resendAdapter, verifySvix, svixSignature, parseResendEvent, stripQuotedReply, parseAddress } from '../../supabase/functions/_shared/channels/resend.ts';
import { registryFromEnv } from '../../supabase/functions/_shared/channels/registry.ts';
import { NetworkError, type FetchLike, type OutboundMessage } from '../../supabase/functions/_shared/channels/types.ts';
import { safeEqual } from '../../supabase/functions/_shared/crypto.ts';

type Call = { url: string; init: RequestInit };
function mockFetch(...responses: (Response | Error)[]): { f: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  return { calls, f: async (url, init) => { calls.push({ url, init }); const r = responses.shift() ?? new Response('{}', { status: 500 }); if (r instanceof Error) throw r; return r; } };
}
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const sms: OutboundMessage = { channel: 'sms', to: '+15555550001', from: { address: '+15555550199', config: { messaging_service_sid: 'MG123' } }, body: 'Hi Sam', idempotencyKey: 'draft:1' };

test('twilio: form POST via Messaging Service with status callback and basic auth', async () => {
  const m = mockFetch(json({ sid: 'SM1', status: 'queued' }, 201));
  const a = twilioAdapter({ accountSid: 'AC_test', authToken: 'tok', statusCallbackUrl: 'https://fn.example/webhook-twilio?kind=status', fetch: m.f, baseUrl: 'https://twilio.mock' });
  const r = await a.send(sms);
  assert.deepEqual(r, { ok: true, providerMessageId: 'SM1', status: 'queued' });
  assert.equal(m.calls[0].url, 'https://twilio.mock/2010-04-01/Accounts/AC_test/Messages.json');
  const body = new URLSearchParams(String(m.calls[0].init.body));
  assert.equal(body.get('MessagingServiceSid'), 'MG123');
  assert.equal(body.get('From'), null);
  assert.equal(body.get('StatusCallback'), 'https://fn.example/webhook-twilio?kind=status');
  assert.equal((m.calls[0].init.headers as Record<string, string>).Authorization, `Basic ${btoa('AC_test:tok')}`);
  assert.equal(a.idempotentRetries, false);
});

test('twilio: From when no Messaging Service; 21610 is a non-retryable opt-out; 429/5xx retryable', async () => {
  const m = mockFetch(json({ code: 21610, message: 'unsubscribed recipient' }, 400), json({ code: 20429, message: 'too many' }, 429), json({}, 503));
  const a = twilioAdapter({ accountSid: 'AC', authToken: 't', fetch: m.f });
  const r1 = await a.send({ ...sms, from: { address: '+15555550199', config: {} } });
  assert.equal(new URLSearchParams(String(m.calls[0].init.body)).get('From'), '+15555550199');
  assert.deepEqual([r1.ok, !r1.ok && r1.code, !r1.ok && r1.retryable], [false, 'recipient_opted_out', false]);
  const r2 = await a.send(sms); assert.ok(!r2.ok && r2.retryable && r2.code === 'provider_unavailable');
  const r3 = await a.send(sms); assert.ok(!r3.ok && r3.retryable);
});

test('twilio: network failure surfaces as NetworkError (outcome unknown)', async () => {
  const a = twilioAdapter({ accountSid: 'AC', authToken: 't', fetch: mockFetch(new Error('ECONNRESET')).f });
  await assert.rejects(a.send(sms), NetworkError);
});

test('twilio signature: matches the documented HMAC-SHA1 construction, rejects tampering', async () => {
  const url = 'https://fn.example/webhook-twilio';
  const params = { MessageSid: 'SM9', From: '+15555550001', To: '+15555550199', Body: 'hi' };
  const expected = createHmac('sha1', 'secret').update(url + 'Bodyhi' + 'From+15555550001' + 'MessageSidSM9' + 'To+15555550199').digest('base64');
  assert.equal(await twilioSignature('secret', url, params), expected);
  assert.ok(await verifyTwilioSignature('secret', url, params, expected));
  assert.ok(!(await verifyTwilioSignature('secret', url, { ...params, Body: 'STOP' }, expected)));
  assert.ok(!(await verifyTwilioSignature('secret', url + '?x=1', params, expected)));
  assert.ok(!(await verifyTwilioSignature('secret', url, params, null)));
  assert.ok(!(await verifyTwilioSignature('', url, params, expected)));
});

test('twilio parse: inbound with media + OptOutType, status callback', () => {
  const inbound = parseTwilioEvent(formToRecord('MessageSid=SM1&From=%2B15555550001&To=%2B15555550199&Body=STOP&NumMedia=1&MediaUrl0=https%3A%2F%2Fm%2F1&OptOutType=STOP&SmsStatus=received'), null);
  assert.deepEqual(inbound, { kind: 'inbound', messageSid: 'SM1', from: '+15555550001', to: '+15555550199', body: 'STOP', media: ['https://m/1'], optOutType: 'STOP' });
  const st = parseTwilioEvent({ MessageSid: 'SM2', MessageStatus: 'undelivered', ErrorCode: '30003' }, 'status');
  assert.deepEqual(st, { kind: 'status', messageSid: 'SM2', status: 'undelivered', errorCode: '30003' });
  assert.equal(parseTwilioEvent({ Body: 'x' }, null), null);
});

test('whatsapp: session text inside the window, template outside; error codes mapped', async () => {
  const m = mockFetch(json({ messages: [{ id: 'wamid.1' }] }), json({ messages: [{ id: 'wamid.2' }] }), json({ error: { code: 131047, message: 'Re-engagement message' } }, 400), json({ error: { code: 130429 } }, 429));
  const a = whatsappAdapter({ accessToken: 'tok', apiVersion: 'v21.0', fetch: m.f, baseUrl: 'https://graph.mock' });
  const wa: OutboundMessage = { ...sms, channel: 'whatsapp', from: { address: '+15555550198', config: { phone_number_id: 'PN1' } } };
  assert.deepEqual(await a.send(wa), { ok: true, providerMessageId: 'wamid.1', status: 'accepted' });
  assert.equal(m.calls[0].url, 'https://graph.mock/v21.0/PN1/messages');
  const p1 = JSON.parse(String(m.calls[0].init.body));
  assert.deepEqual([p1.type, p1.to, p1.text.body], ['text', '15555550001', 'Hi Sam']);
  await a.send({ ...wa, template: { name: 'checkin_v1', language: 'en_US', params: ['Sam', 'Runtime Motors'] } });
  const p2 = JSON.parse(String(m.calls[1].init.body));
  assert.equal(p2.type, 'template');
  assert.deepEqual(p2.template.components[0].parameters.map((x: { text: string }) => x.text), ['Sam', 'Runtime Motors']);
  const r3 = await a.send(wa); assert.ok(!r3.ok && r3.code === 'whatsapp_window_closed' && !r3.retryable);
  const r4 = await a.send(wa); assert.ok(!r4.ok && r4.code === 'rate_limited' && r4.retryable);
  const r5 = await a.send({ ...wa, from: { address: 'x', config: {} } }); assert.ok(!r5.ok && r5.code === 'provider_config_missing');
});

test('meta signature + verify-token handshake', async () => {
  const raw = '{"object":"whatsapp_business_account","entry":[]}';
  const sig = 'sha256=' + createHmac('sha256', 'appsecret').update(raw).digest('hex');
  assert.ok(await verifyMetaSignature('appsecret', raw, sig));
  assert.ok(!(await verifyMetaSignature('appsecret', raw + ' ', sig)));
  assert.ok(!(await verifyMetaSignature('appsecret', raw, sig.replace('sha256=', 'sha1='))));
  assert.equal(metaVerifyChallenge(new URL('https://x/?hub.mode=subscribe&hub.verify_token=vt&hub.challenge=123'), 'vt'), '123');
  assert.equal(metaVerifyChallenge(new URL('https://x/?hub.mode=subscribe&hub.verify_token=no&hub.challenge=123'), 'vt'), null);
});

test('meta parse: messages, statuses with errors, template status updates', () => {
  const ev = parseMetaWebhook({ object: 'whatsapp_business_account', entry: [
    { id: 'WABA1', changes: [{ field: 'messages', value: { metadata: { phone_number_id: 'PN1' }, contacts: [{ wa_id: '15555550001', profile: { name: 'Sam Lee' } }],
      messages: [{ from: '15555550001', id: 'wamid.in', timestamp: '1773154800', type: 'text', text: { body: 'is it available?' } }, { from: '15555550001', id: 'wamid.btn', timestamp: '1773154801', type: 'button', button: { text: 'STOP' } }],
      statuses: [{ id: 'wamid.out', status: 'failed', timestamp: '1773154802', errors: [{ code: 131050 }] }] } }] },
    { id: 'WABA1', changes: [{ field: 'message_template_status_update', value: { event: 'REJECTED', message_template_id: 77, message_template_name: 'promo', message_template_language: 'en_US', reason: 'INCORRECT_CATEGORY' } }] },
  ] });
  assert.equal(ev.length, 4);
  assert.deepEqual(ev[0], { kind: 'inbound', phoneNumberId: 'PN1', from: '+15555550001', id: 'wamid.in', timestamp: new Date(1773154800000), body: 'is it available?', type: 'text', profileName: 'Sam Lee' });
  assert.equal(ev[1].kind === 'inbound' && ev[1].body, 'STOP');
  assert.deepEqual(ev[2], { kind: 'status', phoneNumberId: 'PN1', id: 'wamid.out', status: 'failed', timestamp: new Date(1773154802000), errorCode: '131050' });
  assert.deepEqual(ev[3], { kind: 'template', wabaId: 'WABA1', templateId: '77', name: 'promo', language: 'en_US', event: 'REJECTED', reason: 'INCORRECT_CATEGORY' });
  assert.deepEqual(parseMetaWebhook({ object: 'page' }), []);
});

test('meta template pull: paging, BODY text and param count; render refuses missing params', async () => {
  const m = mockFetch(
    json({ data: [{ id: '1', name: 'a', language: 'en_US', status: 'APPROVED', category: 'MARKETING', components: [{ type: 'HEADER' }, { type: 'BODY', text: 'Hi {{1}}, {{2}} {{1}}' }] }], paging: { next: 'https://graph.mock/next' } }),
    json({ data: [{ id: '2', name: 'b', language: 'es', status: 'REJECTED', category: 'utility', components: [], rejected_reason: 'NONE' }] }));
  const rows = await fetchTemplates({ accessToken: 't', fetch: m.f, baseUrl: 'https://graph.mock' }, 'WABA1');
  assert.equal(m.calls.length, 2);
  assert.deepEqual(rows.map((r) => [r.name, r.category, r.status, r.param_count]), [['a', 'MARKETING', 'APPROVED', 2], ['b', 'UTILITY', 'REJECTED', 0]]);
  assert.equal(renderTemplate('Hi {{1}}, {{2}} here', ['Sam', 'Runtime']), 'Hi Sam, Runtime here');
  assert.equal(renderTemplate('Hi {{1}}, {{2}} here', ['Sam']), null);
});

test('resend: Idempotency-Key + RFC 8058 one-click headers; error mapping', async () => {
  const m = mockFetch(json({ id: 're_1' }), json({ message: 'rate' }, 429), json({ name: 'validation_error' }, 422));
  const a = resendAdapter({ apiKey: 'key', fetch: m.f, baseUrl: 'https://resend.mock' });
  const em: OutboundMessage = { channel: 'email', to: 'sam@example.com', from: { address: 'sales@dealer.example', config: {} }, body: 'Hello', idempotencyKey: 'draft:9',
    email: { subject: 'Your Tacoma', fromName: 'Runtime "Motors" <x>', listUnsubscribeUrl: 'https://fn.example/unsubscribe?t=abc', listUnsubscribeMailto: 'unsub@dealer.example' } };
  assert.deepEqual(await a.send(em), { ok: true, providerMessageId: 're_1', status: 'sent' });
  const h = m.calls[0].init.headers as Record<string, string>;
  assert.equal(h['Idempotency-Key'], 'draft:9');
  const b = JSON.parse(String(m.calls[0].init.body));
  assert.equal(b.from, 'Runtime Motors x <sales@dealer.example>');
  assert.equal(b.headers['List-Unsubscribe'], '<https://fn.example/unsubscribe?t=abc>, <mailto:unsub@dealer.example?subject=unsubscribe>');
  assert.equal(b.headers['List-Unsubscribe-Post'], 'List-Unsubscribe=One-Click');
  assert.equal(a.idempotentRetries, true);
  const r2 = await a.send(em); assert.ok(!r2.ok && r2.retryable);
  const r3 = await a.send(em); assert.ok(!r3.ok && r3.code === 'invalid_email' && !r3.retryable);
});

test('svix: valid signature, rotated keys, tolerance window, tampering', async () => {
  const secret = 'whsec_' + Buffer.from('test-secret-key-0123456789').toString('base64');
  const now = new Date('2026-03-10T15:00:00Z');
  const ts = String(Math.floor(now.getTime() / 1000));
  const body = '{"type":"email.delivered","data":{"email_id":"re_1"}}';
  const expected = 'v1,' + createHmac('sha256', Buffer.from('test-secret-key-0123456789')).update(`msg_1.${ts}.${body}`).digest('base64');
  assert.equal(await svixSignature(secret, 'msg_1', ts, body), expected);
  assert.ok(await verifySvix(secret, { id: 'msg_1', timestamp: ts, signature: `v1,old ${expected}` }, body, now));
  assert.ok(!(await verifySvix(secret, { id: 'msg_1', timestamp: ts, signature: expected }, body + ' ', now)));
  assert.ok(!(await verifySvix(secret, { id: 'msg_1', timestamp: ts, signature: expected }, body, new Date(now.getTime() + 301_000))));
  assert.ok(!(await verifySvix(secret, { id: null, timestamp: ts, signature: expected }, body, now)));
});

test('resend parse: statuses, complaint, inbound reply with quoted history stripped', () => {
  assert.deepEqual(parseResendEvent({ type: 'email.delivered', data: { email_id: 're_1' } }), { kind: 'status', emailId: 're_1', status: 'delivered', error: null });
  assert.deepEqual(parseResendEvent({ type: 'email.bounced', data: { email_id: 're_2' } }), { kind: 'status', emailId: 're_2', status: 'failed', error: 'bounce', bounce: { kind: 'hard', detail: 'bounce', to: null } });
  assert.equal((parseResendEvent({ type: 'email.complained', data: { email_id: 're_3' } }) as { status: string }).status, 'complained');
  const inb = parseResendEvent({ type: 'email.received', data: { email_id: 'in_1', from: 'Sam Lee <Sam@Example.com>', to: ['sales@dealer.example'], subject: 'Re: Tacoma', text: 'stop\n\nOn Tue, Mar 10, 2026 Runtime wrote:\n> Hi Sam, Reply STOP' } });
  assert.deepEqual(inb, { kind: 'inbound', emailId: 'in_1', from: 'sam@example.com', fromName: 'Sam Lee', to: 'sales@dealer.example', subject: 'Re: Tacoma', text: 'stop', html: false });
  assert.equal(parseResendEvent({ type: 'email.opened', data: {} }).kind, 'ignored');
  assert.equal(stripQuotedReply('yes please\n> old'), 'yes please');
  assert.deepEqual(parseAddress('x@y.com'), { email: 'x@y.com', name: null });
});

test('registry: only providers with credentials are registered; mock only when explicitly allowed', () => {
  const env = (o: Record<string, string>) => (k: string) => o[k];
  assert.deepEqual(registryFromEnv(env({})).providers(), []);
  const r = registryFromEnv(env({ TWILIO_ACCOUNT_SID: 'AC', TWILIO_AUTH_TOKEN: 't', RESEND_API_KEY: 'k', SUPABASE_URL: 'https://p.supabase.co' }));
  assert.deepEqual(r.providers().sort(), ['resend', 'twilio']);
  assert.equal(r.get('meta_cloud'), null);
  assert.deepEqual(registryFromEnv(env({ SALESOS_ALLOW_MOCK_PROVIDER: 'true' })).providers(), ['mock']);
});

test('constant-time compare', () => {
  assert.ok(safeEqual('abc', 'abc'));
  assert.ok(!safeEqual('abc', 'abd'));
  assert.ok(!safeEqual('abc', 'abcd'));
});
