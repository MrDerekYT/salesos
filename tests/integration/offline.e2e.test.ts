/**
 * Phase-5 end-to-end against the real migrated Postgres; every provider behind MOCKED HTTP (no credentials, no network):
 *   STOP confirmation outbox retry | Resend bounce -> suppression -> can_send/dispatcher | Resend inbound body fetch |
 *   agent facts with provenance + supersede | WhatsApp template compliance gate | staff phone verification -> CRM-by-text.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MockLanguageModelV4 } from 'ai/test';
import { rpc, sql, uuid, skip } from './helpers.ts';
import { handleTwilioWebhook, type TwilioWebhookDeps } from '../../supabase/functions/webhook-twilio/handler.ts';
import { handleResendWebhook } from '../../supabase/functions/webhook-resend/handler.ts';
import { handleStaffVerification } from '../../supabase/functions/staff-verification/handler.ts';
import { runKeywordReplyWorker } from '../../supabase/functions/keyword-reply-worker/process.ts';
import { syncTemplates } from '../../supabase/functions/whatsapp-template-sync/process.ts';
import { twilioAdapter, twilioSignature } from '../../supabase/functions/_shared/channels/twilio.ts';
import { whatsappAdapter } from '../../supabase/functions/_shared/channels/whatsapp.ts';
import { resendAdapter, svixSignature } from '../../supabase/functions/_shared/channels/resend.ts';
import { createRegistry } from '../../supabase/functions/_shared/channels/registry.ts';
import { createDispatcher } from '../../supabase/functions/_shared/channels/dispatch.ts';
import type { FetchLike } from '../../supabase/functions/_shared/channels/types.ts';
import { runAgentWorker } from '../../supabase/functions/agent-runner/process.ts';
import { staffDepsFromRpc } from '../../supabase/functions/_shared/runtime.ts';
import { stopConfirmationText } from '../../supabase/functions/_shared/opt-out.ts';

const R = String(Math.floor(1000 + Math.random() * 9000));
const TOKEN = 'test_only_twilio_auth_token';
const FN = 'https://project.example/functions/v1';
const SVIX = 'whsec_' + Buffer.from('s'.repeat(24)).toString('base64');
const usage = { inputTokens: { total: 900, noCache: 900, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 120, text: 120, reasoning: 0 } };

type TwilioBehavior = (n: number) => Response | Error | undefined;
function mockTwilio(prefix: string, behave: TwilioBehavior = () => undefined) {
  const calls: URLSearchParams[] = [];
  const f: FetchLike = async (_url, init) => {
    calls.push(new URLSearchParams(String(init.body)));
    const b = behave(calls.length);
    if (b instanceof Error) throw b;
    if (b) return b;
    return new Response(JSON.stringify({ sid: `${prefix}${String(calls.length).padStart(4, '0')}`, status: 'queued' }), { status: 201 });
  };
  return { calls, f };
}
function twilioWorld(f: FetchLike, at: () => Date, staff = false) {
  const registry = createRegistry([twilioAdapter({ accountSid: 'AC_test', authToken: TOKEN, statusCallbackUrl: `${FN}/webhook-twilio?kind=status`, fetch: f, baseUrl: 'https://twilio.mock' })]);
  const dispatcher = createDispatcher({ rpc, registry, now: at, unsubscribeBaseUrl: `${FN}/unsubscribe` });
  const logs: string[] = [];
  const deps: TwilioWebhookDeps = { rpc, dispatcher, now: at, authToken: TOKEN, publicUrl: (req) => `${FN}/webhook-twilio${new URL(req.url).search}`, kickRunner: async () => undefined,
    log: (e: string) => { logs.push(e); }, ...(staff ? { staff: staffDepsFromRpc(rpc, at) } : {}) };
  return { dispatcher, deps, logs };
}
async function twilioPost(deps: TwilioWebhookDeps, params: Record<string, string>) {
  const sig = await twilioSignature(TOKEN, `${FN}/webhook-twilio`, params);
  return handleTwilioWebhook(new Request('http://edge-runtime.internal/webhook-twilio', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Twilio-Signature': sig }, body: new URLSearchParams(params).toString() }), deps);
}
function seedSmsDealer(tag: string) {
  const d = uuid(), rep = uuid(), n = uuid();
  const store = `+1${tag}${R}199`;
  sql(`insert into dealers(id,name,timezone,main_phone) values ('${d}','Gap Motors ${tag}','America/New_York','+15550000100');
       insert into dealer_members(user_id,dealer_id,role) values ('${rep}','${d}','sales');
       insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config) values ('${n}','${d}','sms','twilio','${store}','2025-01-01','{"messaging_service_sid":"MGgap000000000000000000000000001"}');`);
  return { d, rep, n, store };
}
const park = (keep: string[] = []) => sql(`update keyword_replies set status = 'expired', finished_at = now() where status in ('pending','sending')${keep.length ? ` and id not in (${keep.map((k) => `'${k}'`).join(',')})` : ''}`);

// -------------------------------------------------------------------------------------------------------------------------------
test('E2E STOP outbox: a failed confirmation is retried by the worker with backoff and exactly ONE confirmation is delivered', { skip }, async () => {
  const T0 = new Date(); const at = (s: number) => new Date(T0.getTime() + s * 1000); let clock = at(0);
  const tw = mockTwilio(`SMgs${R}`, (n) => (n === 1 ? new Response(JSON.stringify({ code: 20500, message: 'Internal error' }), { status: 503 }) : undefined));
  const { dispatcher, deps } = twilioWorld(tw.f, () => clock);
  const { d, store } = seedSmsDealer('811');
  const c = uuid();
  sql(`insert into contacts(id,dealer_id,first_name,phone_e164) values ('${c}','${d}','Pat','+1811${R}001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','sms','marketing','grant','web_form');`);
  const stop = { MessageSid: `SMstop00000000000000000000000811${R}`, From: `+1811${R}001`, To: store, Body: 'STOP' };

  assert.equal((await twilioPost(deps, stop)).status, 200, 'webhook still answers 200: the opt-out is committed first');
  assert.equal(sql(`select count(*) from contact_dnc where contact_id = '${c}' and channel = 'sms' and cleared_at is null`), '1');
  assert.equal(tw.calls.length, 1, 'first (failed) attempt');
  const kr = sql(`select id from keyword_replies where contact_id = '${c}'`);
  assert.equal(sql(`select status || ':' || attempts from keyword_replies where id = '${kr}'`), 'pending:1');
  assert.ok(Number(sql(`select extract(epoch from next_attempt_at - '${at(0).toISOString()}'::timestamptz) from keyword_replies where id = '${kr}'`)) >= 14, 'backoff scheduled (15s for STOP)');
  assert.equal(sql(`select count(*) from messages where contact_id = '${c}' and direction = 'outbound'`), '0', 'a retryable failure leaves no message row (only terminal outcomes are logged)');
  park([kr]);

  clock = at(5);
  assert.equal((await runKeywordReplyWorker({ rpc, dispatcher, now: () => clock })).claimed, 0, 'not due yet');
  assert.equal(tw.calls.length, 1);
  clock = at(20);
  const w = await runKeywordReplyWorker({ rpc, dispatcher, now: () => clock });
  assert.deepEqual([w.claimed, w.sent], [1, 1]);
  assert.equal(tw.calls.length, 2);
  assert.equal(tw.calls[1].get('Body'), stopConfirmationText('Gap Motors 811'));
  assert.equal(sql(`select status from keyword_replies where id = '${kr}'`), 'sent');
  assert.equal(sql(`select count(*) from messages where contact_id = '${c}' and direction = 'outbound' and status in ('sent','accepted','queued')`), '1', 'exactly one confirmation message');

  // replays: worker, second STOP, webhook retry => nothing more
  clock = at(900);
  assert.equal((await runKeywordReplyWorker({ rpc, dispatcher, now: () => clock })).claimed, 0);
  assert.equal((await twilioPost(deps, stop)).status, 200);
  assert.equal((await twilioPost(deps, { ...stop, MessageSid: `SMstop00000000000000000000000812${R}`, Body: 'stop' })).status, 200);
  assert.equal(tw.calls.length, 2);
  assert.equal(sql(`select count(*) from keyword_replies where contact_id = '${c}'`), '1');
});

test('E2E STOP outbox: a send with an unknown outcome (network cut) is NOT resent; a person is told; outbound is still blocked', { skip }, async () => {
  const T0 = new Date(); let clock = T0;
  const tw = mockTwilio(`SMgu${R}`, () => new Error('socket hang up'));
  const { dispatcher, deps } = twilioWorld(tw.f, () => clock);
  const { d, store } = seedSmsDealer('812');
  const c = uuid();
  sql(`insert into contacts(id,dealer_id,phone_e164) values ('${c}','${d}','+1812${R}001');`);
  assert.equal((await twilioPost(deps, { MessageSid: `SMstop00000000000000000000000821${R}`, From: `+1812${R}001`, To: store, Body: 'Stop' })).status, 200);
  const kr = sql(`select id from keyword_replies where contact_id = '${c}'`);
  assert.equal(sql(`select status from keyword_replies where id = '${kr}'`), 'unknown');
  assert.equal(sql(`select count(*) from agent_inbox_items where dealer_id = '${d}' and kind = 'send_failed'`), '1');
  park([]);
  clock = new Date(T0.getTime() + 3600_000);
  assert.equal((await runKeywordReplyWorker({ rpc, dispatcher, now: () => clock })).claimed, 0);
  assert.equal(tw.calls.length, 1, 'never blind-resent on a non-idempotent provider');
  assert.equal(sql(`select count(*) from contact_dnc where contact_id = '${c}' and cleared_at is null`), '1');
});

// -------------------------------------------------------------------------------------------------------------------------------
function resendWorld(tag: string, apiFetch?: FetchLike) {
  const sent: string[] = [];
  const registry = createRegistry([resendAdapter({ apiKey: 'test_only', baseUrl: 'https://resend.mock', fetch: async () => { sent.push('send'); return new Response(JSON.stringify({ id: `re_sent_${tag}` }), { status: 200 }); } })]);
  const dispatcher = createDispatcher({ rpc, registry, now: () => new Date(), unsubscribeBaseUrl: `${FN}/unsubscribe` });
  const logs: string[] = [];
  const deps = { rpc, dispatcher, now: () => new Date(), webhookSecret: SVIX, api: apiFetch ? { apiKey: 'test_only', baseUrl: 'https://resend.mock', fetch: apiFetch } : null, log: (e: string) => { logs.push(e); } };
  const post = async (obj: unknown, id: string) => {
    const b = JSON.stringify(obj); const ts = String(Math.floor(Date.now() / 1000));
    return handleResendWebhook(new Request('https://x/webhook-resend', { method: 'POST', body: b, headers: { 'svix-id': id, 'svix-timestamp': ts, 'svix-signature': await svixSignature(SVIX, id, ts, b) } }), deps);
  };
  return { sent, dispatcher, post, logs };
}
function seedEmailDealer(tag: string) {
  const d = uuid(), n = uuid(); const addr = `sales${tag}${R}@gap.example`;
  sql(`insert into dealers(id,name,postal_address) values ('${d}','Gap Mail ${tag}','1 Main St, Albany NY');
       insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at) values ('${n}','${d}','email','resend','${addr}','2025-01-01');`);
  return { d, n, addr };
}
function outboundEmail(d: string, n: string, contactEmail: string, providerId: string) {
  const c = uuid(); const l = uuid();
  sql(`insert into contacts(id,dealer_id,first_name,email) values ('${c}','${d}','Ed','${contactEmail}');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','email','conversational','grant','web_form');
       insert into leads(id,dealer_id,contact_id,stage) values ('${l}','${d}','${c}','qualifying');
       insert into messages(dealer_id,lead_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) values ('${d}','${l}','${c}','${n}','email','outbound','human','Your quote','${providerId}','sent');`);
  return { c, l };
}

test('E2E bounces: hard bounce suppresses; soft bounces count to the limit; can_send and the dispatcher both refuse; replays never double count', { skip }, async () => {
  const w = resendWorld('b1');
  const { d, n } = seedEmailDealer('821');
  const hard = outboundEmail(d, n, `ed.hard${R}@example.com`, `re_h_${R}`);
  const bounced = (id: string, to: string, type: string) => ({ type: 'email.bounced', data: { email_id: id, to: [to], bounce: { type, subType: type === 'Permanent' ? 'General' : 'MailboxFull', message: 'smtp; 550' } } });
  const canSend = (c: string) => rpc<{ verdict: string; code: string }>('can_send', { p_dealer_id: d, p_contact_id: c, p_channel: 'email', p_purpose: 'conversational', p_kind: 'reply', p_number_id: n, p_body: 'Following up on your quote.' });

  assert.notEqual((await canSend(hard.c)).code, 'email_suppressed');
  assert.equal((await w.post(bounced(`re_h_${R}`, `ed.hard${R}@example.com`, 'Permanent'), `msg_h_${R}`)).status, 200);
  assert.equal(sql(`select reason from email_suppressions where dealer_id = '${d}' and email = 'ed.hard${R}@example.com' and cleared_at is null`), 'hard_bounce');
  assert.equal(sql(`select status from messages where provider_message_id = 're_h_${R}'`), 'failed');
  const dec = await canSend(hard.c);
  assert.deepEqual([dec.verdict, dec.code], ['veto', 'email_suppressed']);
  const r = await w.dispatcher.send({ numberId: n, contactId: hard.c, body: 'Hi again', idempotencyKey: `e2e-b-${R}`, purpose: 'conversational', kind: 'reply', subject: 'Your quote' });
  assert.ok(!r.ok && r.error === 'email_suppressed');
  assert.equal(w.sent.length, 0, 'the provider is never called for a suppressed address');
  assert.equal((await w.post(bounced(`re_h_${R}`, `ed.hard${R}@example.com`, 'Permanent'), `msg_h_${R}`)).status, 200, 'webhook retry');
  assert.equal(sql(`select count(*) from email_bounce_events where dealer_id = '${d}'`), '1');

  // soft: 1, 2 => still sendable; 3rd (distinct events) => suppressed
  const soft = outboundEmail(d, n, `ed.soft${R}@example.com`, `re_s_${R}`);
  for (let i = 1; i <= 3; i++) {
    await w.post(bounced(`re_s_${R}`, `ed.soft${R}@example.com`, 'Transient'), `msg_s${i}_${R}`);
    assert.equal(sql(`select count(*) from email_suppressions where dealer_id = '${d}' and email = 'ed.soft${R}@example.com' and cleared_at is null`), i === 3 ? '1' : '0', `after soft bounce ${i}`);
  }
  await w.post(bounced(`re_s_${R}`, `ed.soft${R}@example.com`, 'Transient'), `msg_s3_${R}`);
  assert.equal(sql(`select count(*) from email_bounce_events where dealer_id = '${d}' and kind = 'soft'`), '3', 'replayed svix id not recounted');
  assert.equal(sql(`select reason from email_suppressions where dealer_id = '${d}' and email = 'ed.soft${R}@example.com'`), 'soft_bounce_limit');
  assert.equal((await canSend(soft.c)).code, 'email_suppressed');

  // operator clears => sendable again (audit kept)
  const mgr = uuid(); sql(`insert into dealer_members(user_id,dealer_id,role) values ('${mgr}','${d}','manager')`);
  await rpc('clear_email_suppression', { p_dealer_id: d, p_email: `ed.soft${R}@example.com`, p_note: 'Customer confirmed mailbox is fixed', p_actor: mgr });
  assert.notEqual((await canSend(soft.c)).code, 'email_suppressed');
  assert.equal(sql(`select count(*) from email_suppressions where dealer_id = '${d}' and email = 'ed.soft${R}@example.com' and cleared_at is not null`), '1', 'cleared, not deleted');
});

test('E2E Resend inbound: body fetched from the (mock) API when the webhook has none; subject fallback on 404; 429 => 500 then retry succeeds', { skip }, async () => {
  const { d, addr } = seedEmailDealer('822');
  let mode: 'ok' | '404' | '429' = 'ok'; const reqs: string[] = [];
  const api: FetchLike = async (url) => {
    reqs.push(url);
    if (mode === '429') return new Response(JSON.stringify({ message: 'rate limit' }), { status: 429 });
    if (mode === '404') return new Response(JSON.stringify({ message: 'not found' }), { status: 404 });
    return new Response(JSON.stringify({ text: 'Is the Tacoma still available? I can come Saturday.\n\nOn Mon, Sam wrote:\n> old', html: null, authentication: { spf: 'pass', dkim: 'pass', dmarc: 'pass' }, attachments: [{ id: 'a1' }] }), { status: 200 });
  };
  const w = resendWorld('c1', api);
  const ev = (id: string, from: string) => ({ type: 'email.received', data: { email_id: id, from: `Sam <${from}>`, to: [addr], subject: 'Re: your Tacoma' } });
  const em1 = `sam1${R}@example.com`;
  assert.equal((await w.post(ev(`in_${R}_1`, em1), `msg_in1_${R}`)).status, 200);
  assert.match(reqs[0], /\/emails\/receiving\/in_\d+_1\?html_format=cid$/);
  const row1 = sql(`select body || '|' || (media->'email'->>'body_source') || '|' || (media->'email'->'auth'->>'dmarc') || '|' || (media->'email'->>'attachments') from messages where dealer_id = '${d}' and direction = 'inbound' and provider_message_id = 'in_${R}_1'`);
  assert.equal(row1, 'Is the Tacoma still available? I can come Saturday.|text|pass|1');
  assert.equal(sql(`select count(*) from agent_jobs where lead_id = (select lead_id from messages where provider_message_id = 'in_${R}_1') and status = 'queued'`), '1');

  mode = '404';
  assert.equal((await w.post(ev(`in_${R}_2`, `sam2${R}@example.com`), `msg_in2_${R}`)).status, 200);
  assert.equal(sql(`select body || '|' || (media->'email'->>'body_source') from messages where provider_message_id = 'in_${R}_2'`), 'Re: your Tacoma|subject_only');

  mode = '429';
  assert.equal((await w.post(ev(`in_${R}_3`, `sam3${R}@example.com`), `msg_in3_${R}`)).status, 500);
  assert.equal(sql(`select status from event_log where provider = 'resend' and external_id = 'msg_in3_${R}'`), 'failed');
  assert.equal(sql(`select count(*) from messages where provider_message_id = 'in_${R}_3'`), '0');
  mode = 'ok';
  assert.equal((await w.post(ev(`in_${R}_3`, `sam3${R}@example.com`), `msg_in3_${R}`)).status, 200, 'Resend retries the same svix id');
  assert.equal(sql(`select count(*) from messages where provider_message_id = 'in_${R}_3'`), '1');
  assert.equal(sql(`select status from event_log where provider = 'resend' and external_id = 'msg_in3_${R}'`), 'processed');
});

// -------------------------------------------------------------------------------------------------------------------------------
test('E2E facts: the agent records a VIN + budget with provenance; a later message supersedes (history kept); bad VIN never lands', { skip }, async () => {
  const T0 = new Date(); let clock = T0; const at = (s: number) => new Date(T0.getTime() + s * 1000);
  const tw = mockTwilio(`SMfc${R}`);
  const { dispatcher, deps } = twilioWorld(tw.f, () => clock);
  const { d, store } = seedSmsDealer('831');
  const c = uuid();
  sql(`insert into contacts(id,dealer_id,first_name,phone_e164) values ('${c}','${d}','Dana','+1831${R}001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','sms','conversational','grant','web_form');`);
  const inbound = (sid: string, body: string) => twilioPost(deps, { MessageSid: sid, AccountSid: 'AC_test', From: `+1831${R}001`, To: store, Body: body, NumMedia: '0', SmsStatus: 'received' });
  const calls = (...tc: { tool: string; input: unknown }[]) => { let i = 0;
    return new MockLanguageModelV4({ doGenerate: async () => {
      const x = tc[i++];
      if (x) return { content: [{ type: 'tool-call', toolCallId: `t${i}`, toolName: x.tool, input: JSON.stringify(x.input) }], finishReason: { unified: 'tool-calls', raw: 'tool_calls' }, usage, warnings: [] } as never;
      return { content: [{ type: 'text', text: 'Noted.' }], finishReason: { unified: 'stop', raw: 'stop' }, usage, warnings: [] } as never;
    } }); };
  const run = async (model: MockLanguageModelV4, lead: string) => {
    sql(`update agent_jobs set status = 'skipped', last_error = 'parked by e2e' where status in ('queued','running') and lead_id <> '${lead}'`);
    return runAgentWorker({ rpc, dispatcher, now: () => clock, sleep: async () => undefined, model, modelId: 'mock/agent', workerId: 'e2e-facts' });
  };

  const sid1 = `SMfc00000000000000000000000000831${R}`;
  await inbound(sid1, 'Hi, my trade-in VIN is 1HGCM82633A004352 and my budget is about $38,000.');
  const lead = sql(`select lead_id from messages where provider_message_id = '${sid1}'`);
  const m1 = sql(`select id from messages where provider_message_id = '${sid1}'`);
  clock = at(10);
  const s1 = await run(calls(
    { tool: 'record_customer_fact', input: { key: 'trade_in_vin', value: '1HGCM82633A004352', confidence: 0.95, evidence_quote: 'my trade-in VIN is 1HGCM82633A004352' } },
    { tool: 'record_customer_fact', input: { key: 'budget_max_cents', value: 3800000, confidence: 0.8, evidence_quote: 'my budget is about $38,000' } },
    { tool: 'record_customer_fact', input: { key: 'trade_in_vin', value: '1HGCM82633A004353', confidence: 0.95, evidence_quote: 'VIN is 1HGCM82633A004353' } },
    { tool: 'send_message', input: { body: 'Thanks Dana, I have your trade-in details and budget. Want to come see something this week?' } },
  ), lead);
  assert.equal(s1.completed, 1, JSON.stringify(s1));
  assert.equal(sql(`select string_agg(fact_key || '=' || value::text, ',' order by fact_key) from customer_facts where lead_id = '${lead}' and superseded_at is null`), 'budget_max_cents=3800000,trade_in_vin="1HGCM82633A004352"');
  assert.equal(sql(`select count(*) from customer_facts where lead_id = '${lead}' and message_id = '${m1}' and run_id is not null and source = 'ai_extracted' and confidence is not null and evidence_quote is not null`), '2', 'provenance: message + run + quote + confidence');

  const sid2 = `SMfc00000000000000000000000000832${R}`;
  clock = at(200);
  await inbound(sid2, 'Actually I can only do $35,000 max.');
  clock = at(210);
  const s2 = await run(calls({ tool: 'record_customer_fact', input: { key: 'budget_max_cents', value: 3500000, confidence: 0.9, evidence_quote: 'I can only do $35,000 max' } },
    { tool: 'send_message', input: { body: 'Understood, I will keep to your updated budget. Want to come see something this week?' } }), lead);
  assert.equal(s2.completed, 1, JSON.stringify(s2));
  assert.equal(sql(`select value::text from customer_facts where lead_id = '${lead}' and fact_key = 'budget_max_cents' and superseded_at is null`), '3500000');
  assert.equal(sql(`select count(*) from customer_facts where lead_id = '${lead}' and fact_key = 'budget_max_cents'`), '2', 'history kept');
  assert.equal(sql(`select count(*) from customer_facts f where f.lead_id = '${lead}' and f.fact_key = 'budget_max_cents' and f.supersedes_id is not null and f.supersedes_id = (select id from customer_facts where lead_id = '${lead}' and fact_key = 'budget_max_cents' and superseded_at is not null)`), '1');
  assert.equal(sql(`select message_id from customer_facts where lead_id = '${lead}' and fact_key = 'budget_max_cents' and superseded_at is null`), sql(`select id from messages where provider_message_id = '${sid2}'`));
  assert.equal(sql(`select count(*) from customer_facts where lead_id = '${lead}' and fact_key = 'trade_in_vin'`), '1', 'invalid VIN never persisted');
});

// -------------------------------------------------------------------------------------------------------------------------------
test('E2E WhatsApp templates: sync flags a marketing template without opt-out wording; the dispatcher gate blocks it, allows compliant ones', { skip }, async () => {
  const d = uuid(), n = uuid(), c = uuid(); const waba = `WABA841${R}`;
  sql(`insert into dealers(id,name) values ('${d}','WA Gap Motors');
       insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config) values ('${n}','${d}','whatsapp','meta_cloud','+1841${R}199','2025-01-01','{"phone_number_id":"PN841${R}","waba_id":"${waba}"}');
       insert into contacts(id,dealer_id,first_name,phone_e164) values ('${c}','${d}','Lena','+1841${R}001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','whatsapp','marketing','grant','web_form');`);
  const tpl = (name: string, category: string, text: string, buttons?: string[]) => ({ id: `${name}${R}`, name, language: 'en_US', status: 'APPROVED', category,
    components: [{ type: 'BODY', text }, ...(buttons ? [{ type: 'BUTTONS', buttons: buttons.map((t) => ({ type: 'QUICK_REPLY', text: t })) }] : [])] });
  const graph: string[] = []; const sends: string[] = [];
  const f: FetchLike = async (url, init) => {
    graph.push(url);
    if (url.includes('/message_templates')) return new Response(JSON.stringify({ data: [
      tpl('gap_promo_bad', 'MARKETING', 'Hi {{1}}, our sale is on!'),
      tpl('gap_promo_text', 'MARKETING', 'Hi {{1}}, our sale is on! Reply STOP to opt out.'),
      tpl('gap_promo_btn', 'MARKETING', 'Hi {{1}}, our sale is on!', ['Stop promotions']),
      tpl('gap_service', 'UTILITY', 'Hi {{1}}, your car is ready.')] }), { status: 200 });
    sends.push(String(init.body));
    return new Response(JSON.stringify({ messages: [{ id: `wamid.gap${R}${sends.length}` }] }), { status: 200 });
  };
  const wa = whatsappAdapter({ accessToken: 'test_only', fetch: f, baseUrl: 'https://graph.mock' });
  const dispatcher = createDispatcher({ rpc, registry: createRegistry([wa]) });
  const scoped = (async (fn: string, args: Record<string, unknown>) => { const r = await rpc<any>(fn, args); return fn === 'list_template_numbers' ? (r as { number_id: string }[]).filter((x) => x.number_id === n) : r; }) as typeof rpc;
  const sync = await syncTemplates(scoped, { accessToken: 'test_only', fetch: f, baseUrl: 'https://graph.mock' }, new Date());
  assert.deepEqual([sync.numbers, sync.templates, sync.errors.length], [1, 4, 0]);
  assert.equal(sql(`select string_agg(name || ':' || compliance_status, ',' order by name) from message_templates where number_id = '${n}'`), 'gap_promo_bad:flagged,gap_promo_btn:ok,gap_promo_text:ok,gap_service:ok');
  assert.equal(sql(`select count(*) from agent_inbox_items where dealer_id = '${d}' and status = 'open' and kind = 'needs_review' and (payload::text || title || coalesce(summary,'')) ilike '%gap_promo_bad%'`), '1', 'one review item for the flagged template');
  await syncTemplates(scoped, { accessToken: 'test_only', fetch: f, baseUrl: 'https://graph.mock' }, new Date());
  assert.equal(sql(`select count(*) from agent_inbox_items where dealer_id = '${d}' and kind = 'needs_review'`), '1', 're-sync does not duplicate');

  const send = (name: string, purpose: 'marketing' | 'transactional', key: string) => dispatcher.send({ numberId: n, contactId: c, body: 'Hi Lena', idempotencyKey: key, purpose, kind: 'followup', template: { name, language: 'en_US', params: ['Lena'] } });
  const bad = await send('gap_promo_bad', 'marketing', `wa-bad-${R}`);
  assert.ok(!bad.ok && bad.error === 'template_noncompliant');
  assert.equal(sends.length, 0, 'noncompliant marketing template never reaches Meta');
  assert.equal((await send('gap_promo_text', 'marketing', `wa-ok1-${R}`)).ok, true);
  assert.equal((await send('gap_promo_btn', 'marketing', `wa-ok2-${R}`)).ok, true);
  assert.equal((await send('gap_service', 'marketing', `wa-cat-${R}`)).ok, false, 'a UTILITY template cannot carry marketing');
  assert.equal((await send('gap_service', 'transactional', `wa-ok3-${R}`)).ok, true);
  assert.equal(sends.length, 3);
  // a manager can override a reviewed flagged template; editing it later re-flags
  const mgr = uuid(); sql(`insert into dealer_members(user_id,dealer_id,role) values ('${mgr}','${d}','manager')`);
  const tid = sql(`select id from message_templates where number_id = '${n}' and name = 'gap_promo_bad'`);
  await rpc('override_template_compliance', { p_template_id: tid, p_note: 'Legal approved this wording, STOP in footer image', p_actor: mgr });
  assert.equal((await send('gap_promo_bad', 'marketing', `wa-ovr-${R}`)).ok, true);
});

// -------------------------------------------------------------------------------------------------------------------------------
test('E2E staff verification: an unverified phone is just a customer; a texted code (mock Twilio, hashed at rest) verifies it; then CRM-by-text works', { skip }, async () => {
  const T0 = new Date(); let clock = T0;
  const tw = mockTwilio(`SMsv${R}`);
  const { dispatcher, deps } = twilioWorld(tw.f, () => clock, true);
  const { d, rep, store } = seedSmsDealer('851');
  const phone = `+1851${R}777`;
  const ident = uuid();
  sql(`insert into staff_identities(id,dealer_id,user_id,channel,address,status) values ('${ident}','${d}','${rep}','sms','${phone}','pending')`);
  const text = (sid: string, body: string) => twilioPost(deps, { MessageSid: sid, AccountSid: 'AC_test', From: phone, To: store, Body: body, NumMedia: '0', SmsStatus: 'received' });

  // 1. unverified => handled as a customer lead, no CRM reply
  assert.equal((await text(`SMsv00000000000000000000000000851${R}`, 'Is the Tacoma still available?')).status, 200);
  assert.equal(sql(`select count(*) from messages where dealer_id = '${d}' and direction = 'inbound' and provider_message_id = 'SMsv00000000000000000000000000851${R}'`), '1');
  assert.equal(tw.calls.length, 0, 'no CRM reply to an unverified phone');

  // 2. verification: start (code is texted, never returned), wrong guess, right guess
  const handler = (user: string | null) => ({ rpc, dispatcher, now: () => clock, authenticate: async () => user });
  const call = (user: string | null, body: unknown) => handleStaffVerification(new Request('https://x/staff-verification', { method: 'POST', body: JSON.stringify(body), headers: { authorization: 'Bearer test' } }), handler(user));
  assert.equal((await call(null, { action: 'start', identity_id: ident })).status, 401);
  assert.equal((await call(uuid(), { action: 'start', identity_id: ident })).status, 403, 'a stranger cannot trigger codes to someone else');
  const start = await call(rep, { action: 'start', identity_id: ident });
  assert.equal(start.status, 200);
  const startBody = await start.text();
  assert.equal(tw.calls.length, 1);
  assert.equal(tw.calls[0].get('To'), phone);
  const code = tw.calls[0].get('Body')!.match(/code is (\d{6})/)![1];
  assert.ok(!startBody.includes(code), 'the code is only ever in the text message');
  assert.equal(sql(`select count(*) from staff_verifications where staff_identity_id = '${ident}' and code_hash <> '${code}' and code_hash is not null`), '1');
  assert.equal(sql(`select count(*) from staff_verifications where code_hash = '${code}'`), '0', 'hashed at rest');
  assert.equal((await call(rep, { action: 'start', identity_id: ident })).status, 429, '60s cooldown');
  assert.equal((await call(uuid(), { action: 'confirm', identity_id: ident, code })).status, 403, 'only the identity owner can confirm');
  const wrong = await call(rep, { action: 'confirm', identity_id: ident, code: code === '000000' ? '111111' : '000000' });
  assert.deepEqual([wrong.status, (await wrong.json()).attempts_left], [400, 4]);
  assert.equal(sql(`select status from staff_identities where id = '${ident}'`), 'pending');
  const okRes = await call(rep, { action: 'confirm', identity_id: ident, code });
  assert.deepEqual([okRes.status, (await okRes.json()).result], [200, 'verified']);
  assert.equal(sql(`select status || ':' || (verified_at is not null) from staff_identities where id = '${ident}'`), 'active:true');
  assert.equal(sql(`select count(*) from staff_verifications where staff_identity_id = '${ident}' and consumed_at is not null`), '1', 'the code is consumed (single use)');
  assert.equal((await call(rep, { action: 'confirm', identity_id: ident, code })).status, 200, 'confirming an already-verified identity is an idempotent no-op');

  // 3. verified => CRM-by-text is answered and never threaded as a customer
  clock = new Date(T0.getTime() + 120_000);
  const sid = `SMsv00000000000000000000000000852${R}`;
  assert.equal((await text(sid, 'help')).status, 200);
  assert.equal(tw.calls.length, 2, 'CRM reply sent');
  assert.equal(tw.calls[1].get('To'), phone);
  assert.match(tw.calls[1].get('Body')!, /find|move|task|lead|help/i);
  assert.equal(sql(`select count(*) from messages where provider_message_id = '${sid}'`), '0', 'staff texts are not customer messages');
});
