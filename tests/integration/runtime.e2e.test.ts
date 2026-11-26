/**
 * Phase-4 end-to-end against the real migrated Postgres, with every provider behind MOCKED HTTP (no credentials, no
 * network): signed webhook -> threading -> keywords -> agent (mock model) -> gates -> rep approval -> sweeper ->
 * Twilio adapter (mock fetch) -> signed status callback. Plus the STOP path and a WhatsApp round trip.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { MockLanguageModelV4 } from 'ai/test';
import { rpc, sql, uuid, skip } from './helpers.ts';
import { handleTwilioWebhook, type TwilioWebhookDeps } from '../../supabase/functions/webhook-twilio/handler.ts';
import { handleMetaWebhook } from '../../supabase/functions/webhook-meta/handler.ts';
import { twilioAdapter, twilioSignature } from '../../supabase/functions/_shared/channels/twilio.ts';
import { whatsappAdapter } from '../../supabase/functions/_shared/channels/whatsapp.ts';
import { createRegistry } from '../../supabase/functions/_shared/channels/registry.ts';
import { createDispatcher } from '../../supabase/functions/_shared/channels/dispatch.ts';
import type { FetchLike } from '../../supabase/functions/_shared/channels/types.ts';
import { runAgentWorker } from '../../supabase/functions/agent-runner/process.ts';
import { runClassifyWorker } from '../../supabase/functions/classify-worker/process.ts';
import { makeSweeperDeps } from '../../supabase/functions/outbound-sweeper/deps.ts';
import { sweep } from '../../supabase/functions/outbound-sweeper/process.ts';
import { stopConfirmationText } from '../../supabase/functions/_shared/opt-out.ts';

/** unique per run so the suite can be re-run against the same database */
const R = String(Math.floor(1000 + Math.random() * 9000));
const TOKEN = 'test_only_twilio_auth_token';
const FN = 'https://project.example/functions/v1';
const usage = { inputTokens: { total: 900, noCache: 900, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 120, text: 120, reasoning: 0 } };

/** Mock Twilio REST API: records every request, answers like Twilio (201 + sid). */
function mockTwilio(prefix = `SMe2e${R}`) {
  const calls: URLSearchParams[] = [];
  const f: FetchLike = async (url, init) => {
    assert.match(url, /^https:\/\/twilio\.mock\/2010-04-01\/Accounts\/AC_test\/Messages\.json$/);
    calls.push(new URLSearchParams(String(init.body)));
    return new Response(JSON.stringify({ sid: `${prefix}${String(calls.length).padStart(4, '0')}`, status: 'queued' }), { status: 201 });
  };
  return { calls, f };
}
function world(f: FetchLike, at: () => Date) {
  const registry = createRegistry([twilioAdapter({ accountSid: 'AC_test', authToken: TOKEN, statusCallbackUrl: `${FN}/webhook-twilio?kind=status`, fetch: f, baseUrl: 'https://twilio.mock' })]);
  const dispatcher = createDispatcher({ rpc, registry, now: at, unsubscribeBaseUrl: `${FN}/unsubscribe` });
  const kicks = { runner: 0 };
  const deps: TwilioWebhookDeps = { rpc, dispatcher, now: at, authToken: TOKEN, publicUrl: (req) => `${FN}/webhook-twilio${new URL(req.url).search}`, kickRunner: async () => { kicks.runner++; }, log: (e: string, x?: unknown) => { if (/error|fail/i.test(e)) console.log('LOG', e, x); } };
  return { dispatcher, deps, kicks };
}
async function twilioPost(deps: TwilioWebhookDeps, params: Record<string, string>, query = '') {
  const sig = await twilioSignature(TOKEN, `${FN}/webhook-twilio${query}`, params);
  return handleTwilioWebhook(new Request(`http://edge-runtime.internal/webhook-twilio${query}`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-Twilio-Signature': sig }, body: new URLSearchParams(params).toString() }), deps);
}
function seedDealer(tag: string) {
  const d = uuid(), rep = uuid(), n = uuid();
  const store = `+1${tag}${R}199`;
  sql(`insert into dealers(id,name,timezone,main_phone) values ('${d}','E2E Motors ${tag}','America/New_York','+15550000100');
       insert into dealer_members(user_id,dealer_id,role) values ('${rep}','${d}','sales');
       insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config)
       values ('${n}','${d}','sms','twilio','${store}','2025-01-01','{"messaging_service_sid":"MGe2e000000000000000000000000001"}');`);
  return { d, rep, n, store };
}

test('E2E main path: inbound SMS -> agent draft -> gates hold -> rep approves -> Twilio (mock) -> delivered callback', { skip }, async () => {
  const T0 = new Date();
  const at = (s: number) => new Date(T0.getTime() + s * 1000);
  let clock = at(0);
  const tw = mockTwilio();
  const { dispatcher, deps, kicks } = world(tw.f, () => clock);
  const { d, rep, store } = seedDealer('801');
  const c = uuid(), v = uuid();
  sql(`insert into contacts(id,dealer_id,first_name,phone_e164) values ('${c}','${d}','Sam','+1801${R}001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','sms','conversational','grant','web_form');
       insert into vehicles(id,dealer_id,vin,year,make,model,trim,price_cents,status) values ('${v}','${d}','3TMCZ5AN1PM080101',2023,'Toyota','Tacoma','SR5',3600000,'available');`);

  // 1. customer texts the store; Twilio calls our webhook (signed)
  const inbound = { MessageSid: `SMin0000000000000000000000000801${R}`, AccountSid: 'AC_test', From: `+1801${R}001`, To: store, Body: 'Is the 2023 Tacoma SR5 still available?', NumMedia: '0', SmsStatus: 'received' };
  const res = await twilioPost(deps, inbound);
  assert.equal(res.status, 200);
  assert.equal(kicks.runner, 1, 'webhook kicks the agent runner');
  const lead = sql(`select lead_id from messages where provider_message_id = '${inbound.MessageSid}'`);
  assert.equal(sql(`select contact_id from leads where id = '${lead}'`), c, 'threaded to the existing contact');
  assert.equal(sql(`select status from event_log where provider = 'twilio' and external_id = '${inbound.MessageSid}'`), 'processed');
  assert.equal(sql(`select count(*) from agent_jobs where lead_id = '${lead}' and status = 'queued'`), '1');
  assert.equal((await twilioPost(deps, inbound)).status, 200);
  assert.equal(sql(`select count(*) from messages where provider_message_id = '${inbound.MessageSid}'`), '1', 'Twilio retry is idempotent');

  // 2. agent runner (mock model): inventory lookup, then send_message
  let step = 0;
  const model = new MockLanguageModelV4({ doGenerate: async () => {
    step++;
    if (step === 1) return { content: [{ type: 'tool-call', toolCallId: 't1', toolName: 'check_inventory', input: JSON.stringify({ vin: '3TMCZ5AN1PM080101' }) }], finishReason: { unified: 'tool-calls', raw: 'tool_calls' }, usage, warnings: [] } as never;
    if (step === 2) return { content: [{ type: 'tool-call', toolCallId: 't2', toolName: 'send_message', input: JSON.stringify({ body: 'Yes, the 2023 Toyota Tacoma SR5 is available at $36,000. Want to come see it this week?' }) }], finishReason: { unified: 'tool-calls', raw: 'tool_calls' }, usage, warnings: [] } as never;
    return { content: [{ type: 'text', text: 'Queued for review.' }], finishReason: { unified: 'stop', raw: 'stop' }, usage, warnings: [] } as never;
  } });
  // the runner is global: park jobs left by other suites so this run claims only our lead
  sql(`update agent_jobs set status = 'skipped', last_error = 'parked by e2e' where status in ('queued','running') and lead_id <> '${lead}'`);
  clock = at(5);
  const slept: number[] = [];
  const run = await runAgentWorker({ rpc, dispatcher, now: () => clock, sleep: async (ms) => { slept.push(ms); }, model, modelId: 'mock/agent', workerId: 'e2e' });
  assert.deepEqual([run.claimed, run.completed, run.held, run.sent], [1, 1, 1, 0], JSON.stringify(run));
  const draft = sql(`select id from outbound_drafts where lead_id = '${lead}'`);
  assert.equal(sql(`select status || ':' || veto_code from outbound_drafts where id = '${draft}'`), 'awaiting_review:needs_approval', 'auto-send is off by default => rep review queue');
  const body = sql(`select body_ai from outbound_drafts where id = '${draft}'`);
  assert.match(body, /\$36,000/);
  assert.match(body, /virtual assistant/i, 'first AI message carries the disclosure');
  assert.match(body, /STOP/, 'first message on the channel carries opt-out language');
  assert.equal(tw.calls.length, 0, 'nothing sent before approval');
  assert.equal(sql(`select count(*) > 5 from before_send_traces where draft_id = '${draft}'`), 't');
  assert.equal(sql(`select string_agg(tool, ',' order by step) from agent_tool_calls where run_id = (select run_id from outbound_drafts where id = '${draft}')`), 'check_inventory,send_message');
  assert.equal(sql(`select status from agent_runs where id = (select run_id from outbound_drafts where id = '${draft}')`), 'completed');
  assert.equal(sql(`select status from agent_jobs where lead_id = '${lead}'`), 'done');

  // classification of the same inbound (mock classifier)
  const clf = new MockLanguageModelV4({ doGenerate: async () => ({ content: [{ type: 'text', text: '{"category":"price_shopper","confidence":0.6,"evidence_quote":"still available","rationale":"availability"}' }], finishReason: { unified: 'stop', raw: 'stop' }, usage, warnings: [] }) as never });
  const cr = await runClassifyWorker({ rpc, model: clf, modelId: 'mock/clf', now: () => clock });
  assert.ok(cr.recorded >= 1);
  assert.equal(sql(`select category from classifications where message_id = (select id from messages where provider_message_id = '${inbound.MessageSid}')`), 'price_shopper');

  // 3. the rep approves (small edit) and the sweeper releases it through the Twilio adapter
  clock = at(20);
  await rpc('approve_draft', { p_draft_id: draft, p_body: body.replace('this week?', 'this week? Saturday works too.'), p_actor: rep, p_now: clock.toISOString() });
  clock = at(30);
  const s = await sweep(makeSweeperDeps(rpc, dispatcher, { now: () => clock }));
  assert.equal(s.drafts.sent, 1, JSON.stringify(s));
  assert.equal(tw.calls.length, 1);
  const sent = tw.calls[0];
  assert.equal(sent.get('To'), `+1801${R}001`);
  assert.equal(sent.get('MessagingServiceSid'), 'MGe2e000000000000000000000000001');
  assert.equal(sent.get('StatusCallback'), `${FN}/webhook-twilio?kind=status`);
  assert.match(sent.get('Body')!, /Saturday works too\./);
  const out = sql(`select id from messages where provider_message_id = 'SMe2e${R}0001'`);
  assert.equal(sql(`select status || ':' || author_kind from messages where id = '${out}'`), 'sent:human');
  assert.equal(sql(`select conversation_id = (select conversation_id from messages where provider_message_id = '${inbound.MessageSid}') from messages where id = '${out}'`), 't', 'same conversation thread');
  assert.equal(sql(`select status from outbound_drafts where id = '${draft}'`), 'sent');
  assert.equal(sql(`select status || ':' || provider_message_id from send_attempts where idempotency_key = 'draft:${draft}'`), `sent:SMe2e${R}0001`);
  assert.equal(sql(`select status from send_reservations where idempotency_key = 'draft:${draft}'`), 'sent');
  // the sweeper running again (or a crash-retry) never re-sends
  const again = await sweep(makeSweeperDeps(rpc, dispatcher, { now: () => at(40) }));
  assert.equal(again.drafts.claimed, 0);
  assert.equal(tw.calls.length, 1);

  // 4. Twilio status callbacks (signed) move the message forward only
  for (const st of ['sent', 'delivered']) assert.equal((await twilioPost(deps, { MessageSid: `SMe2e${R}0001`, MessageStatus: st, AccountSid: 'AC_test' }, '?kind=status')).status, 204);
  assert.equal(sql(`select status from messages where id = '${out}'`), 'delivered');
  await twilioPost(deps, { MessageSid: `SMe2e${R}0001`, MessageStatus: 'sent', AccountSid: 'AC_test' }, '?kind=status');
  assert.equal(sql(`select status from messages where id = '${out}'`), 'delivered', 'late callback does not go backwards');
  assert.equal(sql(`select count(*) from event_log where external_id like 'SMe2e${R}0001:%'`), '2', 'duplicate callback logged once');
  const forged = await handleTwilioWebhook(new Request('http://edge/webhook-twilio?kind=status', { method: 'POST', headers: { 'X-Twilio-Signature': 'AAAA' }, body: `MessageSid=SMe2e${R}0001&MessageStatus=failed` }), deps);
  assert.equal(forged.status, 403);
});

test('E2E STOP: DNC + one confirmation, second STOP silent, retries idempotent, no agent job, follow-ups cancelled', { skip }, async () => {
  const tw = mockTwilio(`SMstp${R}`);
  let clock = new Date();
  const { deps, kicks } = world(tw.f, () => clock);
  const { d, n, store } = seedDealer('802');
  const c = uuid(), l = uuid();
  sql(`insert into contacts(id,dealer_id,first_name,phone_e164) values ('${c}','${d}','Pat','+1802${R}001');
       insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values ('${d}','${c}','sms','marketing','grant','web_form');
       insert into leads(id,dealer_id,contact_id,stage) values ('${l}','${d}','${c}','qualifying');
       insert into followups(dealer_id,lead_id,kind,due_at) values ('${d}','${l}','agent_promise', now() + interval '1 day');
       insert into followup_plans(dealer_id,lead_id,contact_id,trigger_kind,purpose,due_at,expires_at,dedupe_key) values ('${d}','${l}','${c}','stalled','conversational', now() + interval '1 day', now() + interval '10 days', 'e2e-802${R}');`);

  const stop1 = { MessageSid: `SMstop000000000000000000000000801${R}`, From: `+1802${R}001`, To: store, Body: 'STOP', OptOutType: '' };
  assert.equal((await twilioPost(deps, stop1)).status, 200);
  assert.equal(sql(`select count(*) from contact_dnc where contact_id = '${c}' and channel = 'sms' and cleared_at is null`), '1');
  assert.equal(sql(`select source from consent_events where contact_id = '${c}' and action = 'revoke'`), 'sms_keyword');
  assert.equal(tw.calls.length, 1, 'exactly one confirmation');
  assert.equal(tw.calls[0].get('Body'), stopConfirmationText(`E2E Motors 802`));
  assert.equal(sql(`select author_kind || ':' || status from messages where contact_id = '${c}' and direction = 'outbound'`), 'system:sent');
  assert.equal(sql(`select count(*) from agent_jobs where lead_id = '${l}'`), '0', 'STOP never reaches the agent');
  assert.equal(kicks.runner, 0);
  assert.equal(sql(`select status from followups where lead_id = '${l}'`), 'cancelled');
  assert.equal(sql(`select status from followup_plans where lead_id = '${l}'`), 'cancelled');

  clock = new Date(clock.getTime() + 60_000);
  assert.equal((await twilioPost(deps, { ...stop1, MessageSid: `SMstop000000000000000000000000802${R}`, Body: 'stop' })).status, 200);
  assert.equal(tw.calls.length, 1, 'second STOP: no second confirmation');
  assert.equal((await twilioPost(deps, stop1)).status, 200);
  assert.equal(tw.calls.length, 1, 'webhook retry of the first STOP: nothing new');
  assert.equal(sql(`select count(*) from messages where contact_id = '${c}' and direction = 'inbound'`), '2');
  const dec = await rpc<{ verdict: string; code: string }>('can_send', { p_dealer_id: d, p_contact_id: c, p_channel: 'sms', p_purpose: 'marketing', p_kind: 'followup', p_number_id: n, p_body: 'New deals this weekend!' });
  assert.equal(dec.verdict, 'veto');
  assert.equal(dec.code, 'dnc_active');

  // Twilio Advanced Opt-Out handled the keyword itself: we record it but do not send our own confirmation
  const c2 = uuid();
  sql(`insert into contacts(id,dealer_id,phone_e164) values ('${c2}','${d}','+1802${R}002')`);
  await twilioPost(deps, { MessageSid: `SMstop000000000000000000000000803${R}`, From: `+1802${R}002`, To: store, Body: 'Cancel', OptOutType: 'STOP' });
  assert.equal(sql(`select count(*) from contact_dnc where contact_id = '${c2}' and cleared_at is null`), '1');
  assert.equal(tw.calls.length, 1);
});

test('E2E WhatsApp: signed inbound threads + queues the agent; template status push; read receipt', { skip }, async () => {
  const d = uuid(), n = uuid();
  sql(`insert into dealers(id,name) values ('${d}','WA Motors');
       insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config) values ('${n}','${d}','whatsapp','meta_cloud','+1803${R}199','2025-01-01','{"phone_number_id":"PN803${R}","waba_id":"WABA803${R}"}');`);
  await rpc('upsert_message_templates', { p_number_id: n, p_templates: [{ id: `tpl803${R}`, name: 'checkin_v1', language: 'en_US', category: 'UTILITY', status: 'PENDING', body_text: 'Hi {{1}}', param_count: 1 }] });
  const graphCalls: string[] = [];
  const wa = whatsappAdapter({ accessToken: 'test_only', fetch: async (url) => { graphCalls.push(url); return new Response('{}', { status: 500 }); }, baseUrl: 'https://graph.mock' });
  const deps = { rpc, dispatcher: createDispatcher({ rpc, registry: createRegistry([wa]) }), now: () => new Date(), appSecret: 'test_app_secret', verifyToken: 'vt' };
  const post = (obj: unknown) => { const raw = JSON.stringify(obj); return handleMetaWebhook(new Request('https://x/webhook-meta', { method: 'POST', body: raw, headers: { 'X-Hub-Signature-256': 'sha256=' + createHmac('sha256', 'test_app_secret').update(raw).digest('hex') } }), deps); };
  const ts = String(Math.floor(Date.now() / 1000));
  assert.equal((await post({ object: 'whatsapp_business_account', entry: [{ id: `WABA803${R}`, changes: [{ field: 'messages', value: { metadata: { phone_number_id: `PN803${R}` }, contacts: [{ wa_id: `1803${R}001`, profile: { name: 'Lena Park' } }],
    messages: [{ from: `1803${R}001`, id: `wamid.e2e803${R}`, timestamp: ts, type: 'text', text: { body: 'Do you have any hybrids?' } }] } }] }] })).status, 200);
  const lead = sql(`select lead_id from messages where provider_message_id = 'wamid.e2e803${R}'`);
  assert.equal(sql(`select first_name || ' ' || phone_e164 from contacts where id = (select contact_id from leads where id = '${lead}')`), `Lena +1803${R}001`);
  assert.equal(sql(`select count(*) from agent_jobs where lead_id = '${lead}' and status = 'queued'`), '1');
  assert.equal(graphCalls.length, 0, 'no outbound call for a normal message');
  assert.equal((await post({ object: 'whatsapp_business_account', entry: [{ id: `WABA803${R}`, changes: [{ field: 'message_template_status_update', value: { event: 'APPROVED', message_template_id: `tpl803${R}`, message_template_name: 'checkin_v1', message_template_language: 'en_US', reason: 'NONE' } }] }] })).status, 200);
  assert.equal(sql(`select status from message_templates where number_id = '${n}'`), 'APPROVED');
  sql(`insert into messages(dealer_id,lead_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) select dealer_id, lead_id, contact_id, number_id, 'whatsapp','outbound','human','We do!','wamid.out803${R}','sent' from messages where provider_message_id = 'wamid.e2e803${R}'`);
  await post({ object: 'whatsapp_business_account', entry: [{ id: `WABA803${R}`, changes: [{ field: 'messages', value: { metadata: { phone_number_id: `PN803${R}` }, statuses: [{ id: `wamid.out803${R}`, status: 'read', timestamp: ts }] } }] }] });
  assert.equal(sql(`select status from messages where provider_message_id = 'wamid.out803${R}'`), 'read');
});
