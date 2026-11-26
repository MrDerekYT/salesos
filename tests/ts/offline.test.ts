/** Phase 5 unit tests: keyword outbox, Resend bounces + inbound body fetch, facts tool, template gate, staff verification. Mocked HTTP/RPC only. */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isValidVin, validateFact } from '../../supabase/functions/_shared/facts.ts';
import { createAgentTools, type AgentToolDeps } from '../../lib/agent/tools.ts';
import { emptyEvidence } from '../../supabase/functions/_shared/before-send.ts';
import { deliverKeywordReply, attemptKeywordReply, type ClaimedKeywordReply } from '../../supabase/functions/_shared/keyword-replies.ts';
import { runKeywordReplyWorker } from '../../supabase/functions/keyword-reply-worker/process.ts';
import { bounceFrom, fetchReceivedEmail, htmlToText, parseResendEvent, svixSignature } from '../../supabase/functions/_shared/channels/resend.ts';
import { fetchTemplates, hasOptOutButton } from '../../supabase/functions/_shared/channels/whatsapp.ts';
import { handleResendWebhook } from '../../supabase/functions/webhook-resend/handler.ts';
import { createDispatcher, type SendTargetRow } from '../../supabase/functions/_shared/channels/dispatch.ts';
import { createRegistry } from '../../supabase/functions/_shared/channels/registry.ts';
import { mockAdapter } from '../../supabase/functions/_shared/channels/mock.ts';
import { handleStaffVerification, maskPhone } from '../../supabase/functions/staff-verification/handler.ts';
import { stopConfirmationText } from '../../supabase/functions/_shared/opt-out.ts';

type Handler = (args: Record<string, any>) => unknown;
function fakeRpc(handlers: Record<string, Handler>) {
  const calls: { fn: string; args: Record<string, any> }[] = [];
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    calls.push({ fn, args: args as Record<string, any> });
    const h = handlers[fn];
    if (!h) throw new Error(`unexpected rpc ${fn}`);
    return (await h(args as Record<string, any>)) as T;
  };
  return { rpc, calls, count: (fn: string) => calls.filter((c) => c.fn === fn).length };
}
const NOW = new Date('2026-03-10T15:00:00Z');
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status });

// ------------------------------------------------------------------------------------------------ 1. keyword outbox
const claimed = (over: Partial<ClaimedKeywordReply> = {}): ClaimedKeywordReply => ({ reply_id: 'KR1', kind: 'stop', dealer_id: 'D', contact_id: 'C', number_id: 'N', channel: 'sms', attempts: 1, dealer_name: 'Gap Motors', main_phone: null, ...over });
function fakeDispatcher(results: Array<{ ok: true; providerMessageId: string } | { ok: false; error: string; retryable: boolean } | 'throw'>) {
  const sent: { body: string; idempotencyKey: string; subject?: string | null }[] = [];
  return { sent, d: { send: async (r: { body: string; idempotencyKey: string; subject?: string | null }) => { sent.push(r); const x = results.shift() ?? { ok: true as const, providerMessageId: 'P' }; if (x === 'throw') throw new Error('boom'); return x; },
                      sendRaw: async () => ({ ok: true as const, providerMessageId: 'RAW' }) } };
}
test('keyword outbox: a failed send is recorded with its retry decision; the same key kw:<id> is used every attempt', async () => {
  const f = fakeRpc({ finish_keyword_reply: () => 'pending' });
  const disp = fakeDispatcher([{ ok: false, error: 'provider_unavailable', retryable: true }, { ok: true, providerMessageId: 'SM1' }]);
  const logs: string[] = [];
  const r1 = await deliverKeywordReply(claimed(), { rpc: f.rpc, dispatcher: disp.d, now: () => NOW, log: (e) => logs.push(e) });
  assert.deepEqual(r1, { ok: false, status: 'pending', error: 'provider_unavailable' });
  assert.equal(f.calls[0].args.p_retryable, true);
  assert.equal(f.calls[0].args.p_ok, false);
  assert.deepEqual(logs, ['keyword_reply_failed']);
  const f2 = fakeRpc({ finish_keyword_reply: () => 'sent' });
  const r2 = await deliverKeywordReply(claimed({ attempts: 2 }), { rpc: f2.rpc, dispatcher: disp.d, now: () => NOW });
  assert.deepEqual(r2, { ok: true, status: 'sent' });
  assert.deepEqual(disp.sent.map((s) => s.idempotencyKey), ['kw:KR1', 'kw:KR1']);
  assert.equal(disp.sent[0].body, stopConfirmationText('Gap Motors'));
  assert.equal(f2.calls[0].args.p_provider_message_id, 'SM1');
  assert.doesNotMatch(disp.sent[0].body, /sale|offer|deal|%/i);
});
test('keyword outbox: a dispatcher exception becomes a retryable failure (never lost, never thrown into the webhook)', async () => {
  const f = fakeRpc({ finish_keyword_reply: () => 'pending' });
  const r = await deliverKeywordReply(claimed(), { rpc: f.rpc, dispatcher: fakeDispatcher(['throw']).d, now: () => NOW });
  assert.equal(r.ok, false);
  assert.equal(f.calls[0].args.p_retryable, true);
  assert.match(f.calls[0].args.p_error, /dispatch_exception/);
});
test('keyword outbox: unknown / opted-out outcomes are not retryable; a missing number is terminal', async () => {
  const f = fakeRpc({ finish_keyword_reply: () => 'unknown' });
  await deliverKeywordReply(claimed(), { rpc: f.rpc, dispatcher: fakeDispatcher([{ ok: false, error: 'send_outcome_unknown', retryable: false }]).d, now: () => NOW });
  assert.equal(f.calls[0].args.p_retryable, false);
  const g = fakeRpc({ finish_keyword_reply: () => 'gave_up' });
  const disp = fakeDispatcher([]);
  await deliverKeywordReply(claimed({ number_id: null }), { rpc: g.rpc, dispatcher: disp.d, now: () => NOW });
  assert.equal(disp.sent.length, 0);
  assert.equal(g.calls[0].args.p_error, 'number_missing');
});
test('keyword outbox: inline attempt is skipped when another worker holds the row (no claim => no send)', async () => {
  const f = fakeRpc({ begin_keyword_reply: () => [] });
  const disp = fakeDispatcher([]);
  assert.equal(await attemptKeywordReply('KR1', { rpc: f.rpc, dispatcher: disp.d, now: () => NOW }), null);
  assert.equal(disp.sent.length, 0);
});
test('keyword-reply worker: claims due rows, delivers each, summarises sent / retrying / terminal', async () => {
  const outcomes = ['sent', 'pending', 'gave_up'];
  const f = fakeRpc({
    claim_keyword_replies: () => [claimed({ reply_id: 'A' }), claimed({ reply_id: 'B', kind: 'help', main_phone: '+15555550100' }), claimed({ reply_id: 'C', kind: 'start' })],
    finish_keyword_reply: () => outcomes.shift(),
  });
  const disp = fakeDispatcher([{ ok: true, providerMessageId: 'P1' }, { ok: false, error: 'provider_unavailable', retryable: true }, { ok: false, error: 'provider_rejected', retryable: false }]);
  const sum = await runKeywordReplyWorker({ rpc: f.rpc, dispatcher: disp.d, now: () => NOW });
  assert.deepEqual(sum, { claimed: 3, sent: 1, retrying: 1, terminal: 1 });
  assert.deepEqual(disp.sent.map((s) => s.idempotencyKey), ['kw:A', 'kw:B', 'kw:C']);
  assert.match(disp.sent[1].body, /HELP|help|\+15555550100/);
  assert.equal(f.calls[0].args.p_limit, 20);
});

// ------------------------------------------------------------------------------------------------ 2. Resend bounces + inbound body
test('resend bounces: Permanent => hard, Transient / Undetermined => soft, provider suppression => hard; delivery_delayed is not a bounce', () => {
  assert.deepEqual(bounceFrom({ to: ['Ed <ED@Example.com>'], bounce: { type: 'Permanent', subType: 'General', message: 'no such user' } }), { kind: 'hard', detail: 'Permanent: General: no such user', to: 'ed@example.com' });
  assert.equal(bounceFrom({ to: ['a@b.c'], bounce: { type: 'Transient', subType: 'MailboxFull' } }).kind, 'soft');
  assert.equal(bounceFrom({ to: ['a@b.c'], bounce: { type: 'Undetermined' } }).kind, 'soft');
  assert.equal(bounceFrom({}).kind, 'hard');
  const ev = parseResendEvent({ type: 'email.bounced', data: { email_id: 're_9', to: ['x@y.z'], bounce: { type: 'Transient', message: 'full' } } });
  assert.ok(ev.kind === 'status' && ev.status === 'failed' && ev.bounce?.kind === 'soft');
  const sup = parseResendEvent({ type: 'email.suppressed', data: { email_id: 're_10', to: ['x@y.z'] } });
  assert.ok(sup.kind === 'status' && sup.bounce?.kind === 'hard' && sup.bounce.to === 'x@y.z');
  assert.equal(parseResendEvent({ type: 'email.delivery_delayed', data: { email_id: 're_11' } }).kind, 'ignored');
});
test('resend inbound: webhook text absent => text null; html flag set', () => {
  const e = parseResendEvent({ type: 'email.received', data: { email_id: 'in_9', from: 'A <a@b.c>', to: ['s@d.e'], subject: 'Re: x' } });
  assert.ok(e.kind === 'inbound' && e.text === null && e.html === false);
});
test('fetchReceivedEmail: GET /emails/receiving/{id} with the bearer key; prefers text, falls back to html; strips quoted history', async () => {
  const seen: { url: string; auth: string | null }[] = [];
  const f = async (url: string, init: RequestInit) => { seen.push({ url, auth: new Headers(init.headers).get('authorization') }); return json({ text: 'STOP\n\nOn Tue Sam wrote:\n> old', html: '<p>ignored</p>', authentication: { spf: 'pass', dkim: 'pass', dmarc: 'pass' }, attachments: [{ id: 'a' }] }); };
  const r = await fetchReceivedEmail({ apiKey: 'test_key', fetch: f, baseUrl: 'https://resend.mock' }, 'in 1');
  assert.deepEqual(r, { text: 'STOP', source: 'text', authentication: { spf: 'pass', dkim: 'pass', dmarc: 'pass' }, attachments: 1 });
  assert.equal(seen[0].url, 'https://resend.mock/emails/receiving/in%201?html_format=cid');
  assert.equal(seen[0].auth, 'Bearer test_key');
  const h = await fetchReceivedEmail({ apiKey: 'k', fetch: async () => json({ text: null, html: '<style>p{}</style><div>Is the <b>Tacoma</b> still here?<br>Thanks&nbsp;&amp; bye</div>' }) }, 'x');
  assert.deepEqual([h!.source, h!.text], ['html', 'Is the Tacoma still here?\nThanks & bye']);
  assert.equal((await fetchReceivedEmail({ apiKey: 'k', fetch: async () => json({ text: null, html: null }) }, 'x'))!.source, 'empty');
  assert.equal(htmlToText('<script>alert(1)</script>Hi<br/>there'), 'Hi\nthere');
});
test('fetchReceivedEmail: 404/410 => null (use the subject); 429/5xx/401/network THROW so the webhook is retried', async () => {
  assert.equal(await fetchReceivedEmail({ apiKey: 'k', fetch: async () => json({ message: 'nf' }, 404) }, 'x'), null);
  assert.equal(await fetchReceivedEmail({ apiKey: 'k', fetch: async () => json({}, 410) }, 'x'), null);
  for (const st of [429, 500, 503, 401]) await assert.rejects(fetchReceivedEmail({ apiKey: 'k', fetch: async () => json({ message: 'no' }, st) }, 'x'), /resend receiving/);
  await assert.rejects(fetchReceivedEmail({ apiKey: 'k', fetch: async () => { throw new Error('ECONNRESET'); } }, 'x'), /network/);
});

const SECRET = 'whsec_' + Buffer.from('k'.repeat(24)).toString('base64');
function resendHarness(extra: Record<string, Handler> = {}, api: { fetch: (u: string, i: RequestInit) => Promise<Response> } | null = null) {
  const events = new Map<string, string>();
  const f = fakeRpc({
    log_webhook_event: (a) => { const dup = events.get(a.p_external_id) === 'processed'; events.set(a.p_external_id, dup ? 'processed' : 'received'); return [{ event_id: a.p_external_id, duplicate: dup }]; },
    finish_webhook_event: (a) => { events.set(a.p_event_id, a.p_status); return null; },
    resolve_inbound_number: () => [{ number_id: 'N', dealer_id: 'D', provider: 'mock', config: {}, dealer_name: 'Gap Motors', main_phone: null, address: 'sales@gap.example', channel: 'email' }],
    ingest_inbound_message: () => [{ message_id: 'M', dealer_id: 'D', contact_id: 'C', lead_id: 'L', conversation_id: 'CV', duplicate: false }],
    apply_inbound_keyword: () => [{ action: 'agent', reply_kind: null, keyword_reply_id: null, consent_event_id: null }],
    apply_message_status: () => [{ message_id: 'M', applied: true, opted_out: false }],
    record_email_bounce: () => [{ recorded: true, suppressed: true, reason: 'hard_bounce', soft_count: 0 }],
    ...extra,
  });
  const logs: string[] = [];
  const deps = { rpc: f.rpc, dispatcher: fakeDispatcher([]).d, now: () => NOW, webhookSecret: SECRET, api: api ? { apiKey: 'test_key', baseUrl: 'https://resend.mock', fetch: api.fetch } : null, log: (e: string) => logs.push(e) };
  const post = async (obj: unknown, id = 'msg_1') => {
    const b = JSON.stringify(obj); const ts = String(Math.floor(NOW.getTime() / 1000));
    return handleResendWebhook(new Request('https://x/webhook-resend', { method: 'POST', body: b, headers: { 'svix-id': id, 'svix-timestamp': ts, 'svix-signature': await svixSignature(SECRET, id, ts, b) } }), deps);
  };
  return { f, post, logs, events };
}
const received = { type: 'email.received', data: { email_id: 'in_1', from: 'Sam <sam@example.com>', to: ['sales@gap.example'], subject: 'Re: your Tacoma' } };

test('webhook-resend: email.received without text => body fetched from the API and used for threading + keyword detection', async () => {
  let n = 0;
  const h = resendHarness({}, { fetch: async () => { n++; return json({ text: 'STOP please\n> quoted', authentication: { dmarc: 'pass' }, attachments: [] }); } });
  assert.equal((await h.post(received)).status, 200);
  assert.equal(n, 1);
  const ing = h.f.calls.find((c) => c.fn === 'ingest_inbound_message')!.args;
  assert.equal(ing.p_body, 'STOP please');
  assert.deepEqual(ing.p_media, { email: { body_source: 'text', auth: { spf: undefined, dkim: undefined, dmarc: 'pass' }, attachments: 0 } });
  assert.equal(h.f.calls.find((c) => c.fn === 'apply_inbound_keyword')!.args.p_level, 'stop');
});
test('webhook-resend: a body in the webhook is used as-is (no API call)', async () => {
  let n = 0;
  const h = resendHarness({}, { fetch: async () => { n++; return json({}); } });
  await h.post({ type: 'email.received', data: { ...received.data, text: 'Can I come Saturday?' } });
  assert.equal(n, 0);
  assert.equal(h.f.calls.find((c) => c.fn === 'ingest_inbound_message')!.args.p_body, 'Can I come Saturday?');
});
test('webhook-resend: transient API failure => 500 + event marked failed (Resend retries); the retry then succeeds exactly once', async () => {
  let fail = true; let n = 0;
  const h = resendHarness({}, { fetch: async () => { n++; return fail ? json({ message: 'slow down' }, 429) : json({ text: 'yes please' }); } });
  assert.equal((await h.post(received, 'msg_r')).status, 500);
  assert.equal(h.events.get('msg_r'), 'failed');
  assert.equal(h.f.count('ingest_inbound_message'), 0, 'nothing is ingested with a missing body');
  fail = false;
  assert.equal((await h.post(received, 'msg_r')).status, 200);
  assert.equal(h.f.count('ingest_inbound_message'), 1);
  assert.equal(h.f.calls.find((c) => c.fn === 'ingest_inbound_message')!.args.p_body, 'yes please');
  assert.equal((await h.post(received, 'msg_r')).status, 200);
  assert.equal(h.f.count('ingest_inbound_message'), 1, 'processed duplicate is skipped');
  assert.equal(n, 2);
});
test('webhook-resend: 404 or no API key => subject line is the body, flagged in media; never blocks the message', async () => {
  const h = resendHarness({}, { fetch: async () => json({ message: 'gone' }, 404) });
  assert.equal((await h.post(received)).status, 200);
  const a = h.f.calls.find((c) => c.fn === 'ingest_inbound_message')!.args;
  assert.equal(a.p_body, 'Re: your Tacoma');
  assert.deepEqual(a.p_media, { email: { body_source: 'subject_only' } });
  assert.ok(h.logs.includes('inbound_body_unavailable'));
  const g = resendHarness();
  assert.equal((await g.post(received)).status, 200);
  assert.ok(g.logs.includes('inbound_body_not_fetched'));
});
test('webhook-resend: bounces are recorded with the svix id (idempotency), kind and recipient; deliveries are not bounces', async () => {
  const h = resendHarness();
  await h.post({ type: 'email.bounced', data: { email_id: 're_7', to: ['Ed@Example.com'], bounce: { type: 'Transient', subType: 'MailboxFull', message: 'full' } } }, 'msg_b1');
  const b = h.f.calls.find((c) => c.fn === 'record_email_bounce')!.args;
  assert.deepEqual([b.p_provider_message_id, b.p_kind, b.p_email, b.p_provider_event_id], ['re_7', 'soft', 'ed@example.com', 'msg_b1']);
  assert.match(b.p_diagnostic, /Transient/);
  assert.equal(h.f.calls.find((c) => c.fn === 'apply_message_status')!.args.p_status, 'failed');
  assert.ok(h.logs.includes('email_suppressed'));
  await h.post({ type: 'email.delivered', data: { email_id: 're_8' } }, 'msg_b2');
  assert.equal(h.f.count('record_email_bounce'), 1);
});

// ------------------------------------------------------------------------------------------------ 3. facts
test('VIN checksum (ISO 3779)', () => {
  assert.ok(isValidVin('1HGCM82633A004352') && isValidVin('1M8GDM9AXKP042788') && isValidVin(' 1hgcm82633a004352 '));
  assert.ok(!isValidVin('1HGCM82633A004353') && !isValidVin('1HGCM82633A00I352') && !isValidVin('') && !isValidVin('1HGCM82633A00435'));
});
test('validateFact: per-key rules', () => {
  assert.deepEqual(validateFact('budget_max_cents', 3500000), { ok: true, value: 3500000 });
  for (const bad of [35000.5, 500, 60_000_000, '35000', null]) assert.equal(validateFact('budget_max_cents', bad).ok, false);
  assert.deepEqual(validateFact('trade_in_vin', ' 1hgcm82633a004352'), { ok: true, value: '1HGCM82633A004352' });
  assert.equal((validateFact('trade_in_vin', '1HGCM82633A004353') as { code: string }).code, 'invalid_vin');
  assert.deepEqual(validateFact('preferred_trim', ' Limited\n'), { ok: true, value: 'Limited' });
  assert.equal(validateFact('preferred_trim', 'x'.repeat(61)).ok, false);
  assert.equal(validateFact('purchase_timeframe', 'within_30_days').ok, true);
  assert.equal(validateFact('purchase_timeframe', 'soon').ok, false);
  assert.equal(validateFact('wants_financing', 'yes').ok, false);
  assert.equal((validateFact('credit_score', 700) as { code: string }).code, 'invalid_key');
});
const factDeps = (rec: { facts: any[] }, result: any = { result: 'inserted', factId: 'F1' }): AgentToolDeps => ({
  proposeSend: async () => ({ final: 'held' }), updateLeadState: async () => 'noop', scheduleFollowup: async () => ({ followupId: 'f' }),
  recordFact: async (a) => { rec.facts.push(a); return result; },
  searchKnowledge: async () => [], handoff: async () => ({ inboxItemId: 'i' }), searchInventory: async () => [], bookTestDrive: async () => ({ status: 'requested', appointmentId: 'a' }),
  requestAppraisal: async () => ({ appraisalId: 'p', expectedResponseHours: 24 }), createPrequalLink: async () => ({ url: 'u', expiresAt: 'e' }),
});
const parses = (schema: unknown, v: unknown) => (schema as { safeParse(v: unknown): { success: boolean } }).safeParse(v);
type Exec = (a: unknown, o: unknown) => Promise<any>;
const runTool = (t: { execute?: unknown }, args: unknown) => (t.execute as Exec)(args, { toolCallId: 't', messages: [] });
test('record_customer_fact: validates before calling the database; identity is never model-controlled; results teach', async () => {
  const rec = { facts: [] as any[] };
  const tools = createAgentTools({ dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence: emptyEvidence(), deps: factDeps(rec), now: () => NOW });
  const ok = await runTool(tools.record_customer_fact, { key: 'trade_in_vin', value: '1hgcm82633a004352', confidence: 0.9, evidence_quote: 'my trade VIN is 1HGCM82633A004352' });
  assert.equal(ok.ok, true);
  assert.deepEqual(rec.facts[0], { key: 'trade_in_vin', value: '1HGCM82633A004352', confidence: 0.9, quote: 'my trade VIN is 1HGCM82633A004352' });
  const badVin = await runTool(tools.record_customer_fact, { key: 'trade_in_vin', value: '1HGCM82633A004353', confidence: 0.9, evidence_quote: 'VIN 1HGCM82633A004353' });
  assert.equal(badVin.error.code, 'invalid_vin');
  assert.equal((await runTool(tools.record_customer_fact, { key: 'budget_max_cents', value: 35000, confidence: 0.9, evidence_quote: 'max 35k' })).error.code, 'invalid_value');
  assert.equal((await runTool(tools.record_customer_fact, { key: 'preferred_trim', value: 'Limited', confidence: 0.2, evidence_quote: 'limited maybe' })).error.code, 'low_confidence');
  assert.equal(rec.facts.length, 1, 'rejected facts never reach the database');
  // the strict schema refuses tenancy fields and unknown keys
  assert.equal(parses(tools.record_customer_fact.inputSchema, { key: 'wants_financing', value: true, confidence: 0.8, evidence_quote: 'will finance', lead_id: 'x' }).success, false);
  assert.equal(parses(tools.record_customer_fact.inputSchema, { key: 'ssn', value: '1', confidence: 0.8, evidence_quote: 'abc' }).success, false);
  // database-side refusals come back as teaching errors; kept/stale are ok-with-note
  const rej = createAgentTools({ dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence: emptyEvidence(), deps: factDeps(rec, { result: 'rejected', code: 'quote_not_found', message: 'not in the thread' }), now: () => NOW });
  assert.equal((await runTool(rej.record_customer_fact, { key: 'wants_financing', value: true, confidence: 0.9, evidence_quote: 'invented' })).error.code, 'quote_not_found');
  const stale = createAgentTools({ dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence: emptyEvidence(), deps: factDeps(rec, { result: 'stale' }), now: () => NOW });
  const s = await runTool(stale.record_customer_fact, { key: 'wants_financing', value: true, confidence: 0.9, evidence_quote: 'will finance' });
  assert.deepEqual([s.ok, s.result], [true, 'stale']);
});
test('update_lead_state no longer accepts free-form customer_facts (they go through record_customer_fact)', () => {
  const tools = createAgentTools({ dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence: emptyEvidence(), deps: factDeps({ facts: [] }), now: () => NOW });
  assert.equal(parses(tools.update_lead_state.inputSchema, { stage: 'qualified', confidence: 0.9, reason: 'wants to buy', evidence_quote: 'ready', customer_facts: { budget_max_cents: 1 } }).success, false);
});

// ------------------------------------------------------------------------------------------------ 4. WhatsApp template compliance
test('hasOptOutButton: only a quick-reply button that says stop/unsubscribe/opt out counts', () => {
  assert.ok(hasOptOutButton([{ type: 'BODY', text: 'x' }, { type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Stop promotions' }] }]));
  assert.ok(hasOptOutButton([{ type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Unsubscribe' }] }]));
  assert.ok(!hasOptOutButton([{ type: 'BUTTONS', buttons: [{ type: 'URL', text: 'Stop by today', url: 'https://x' }] }]));
  assert.ok(!hasOptOutButton([{ type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Book a test drive' }] }]));
  assert.ok(!hasOptOutButton(undefined));
});
test('fetchTemplates carries has_opt_out_button into the sync payload', async () => {
  const f = async () => json({ data: [
    { id: '1', name: 'promo', language: 'en_US', status: 'APPROVED', category: 'MARKETING', components: [{ type: 'BODY', text: 'Hi {{1}}' }, { type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Stop promotions' }] }] },
    { id: '2', name: 'plain', language: 'en_US', status: 'APPROVED', category: 'MARKETING', components: [{ type: 'BODY', text: 'Hi' }] }] });
  const rows = await fetchTemplates({ accessToken: 'test', fetch: f, baseUrl: 'https://graph.mock' }, 'WABA');
  assert.deepEqual(rows.map((r) => r.has_opt_out_button), [true, false]);
});
const tgt = (over: Partial<SendTargetRow> = {}): SendTargetRow => ({
  dealer_id: 'D', dealer_name: 'Gap Motors', postal_address: '1 Main St', main_phone: null,
  number: { id: 'N', channel: 'whatsapp', provider: 'mock', address: '+15555550198', status: 'active', config: {} },
  contact: { id: 'C', first_name: 'Sam', phone_e164: '+15555550001', email: 'sam@example.com' }, whatsapp_window_open: false, ...over,
});
test('dispatcher: a marketing template that fails the compliance gate is NOT sent, and no send attempt is claimed', async () => {
  const mock = mockAdapter();
  const f = fakeRpc({ get_send_target: () => tgt(), check_template_send: () => ({ allowed: false, code: 'template_noncompliant', flags: ['missing_opt_out'] }), claim_send_attempt: () => [{ decision: 'proceed' }], complete_send_attempt: () => null });
  const r = await createDispatcher({ rpc: f.rpc, registry: createRegistry([mock]) }).send({ numberId: 'N', contactId: 'C', body: 'Hi', idempotencyKey: 'k', purpose: 'marketing', kind: 'followup', template: { name: 'promo', language: 'en_US', params: ['Sam'] } });
  assert.ok(!r.ok && r.error === 'template_noncompliant' && r.detail === 'missing_opt_out' && !r.retryable);
  assert.equal(mock.sent.length, 0);
  assert.equal(f.count('claim_send_attempt'), 0);
  assert.deepEqual([f.calls[1].args.p_name, f.calls[1].args.p_purpose], ['promo', 'marketing']);
});
test('dispatcher: email to a suppressed address is refused (system confirmations included)', async () => {
  const mock = mockAdapter();
  const f = fakeRpc({ get_send_target: () => tgt({ number: { id: 'N', channel: 'email', provider: 'mock', address: 'sales@gap.example', status: 'active', config: {} }, email_suppressed: true }) });
  const r = await createDispatcher({ rpc: f.rpc, registry: createRegistry([mock]), unsubscribeBaseUrl: 'https://fn/unsubscribe' }).send({ numberId: 'N', contactId: 'C', body: 'You are unsubscribed', idempotencyKey: 'kw:1', purpose: 'transactional', kind: 'system' });
  assert.ok(!r.ok && r.error === 'email_suppressed' && !r.retryable);
  assert.equal(mock.sent.length, 0);
});

// ------------------------------------------------------------------------------------------------ 5. staff verification
function staffHarness(handlers: Record<string, Handler> = {}, user: string | null = 'U1', sendOk = true) {
  const sent: { to: string; body: string; key: string; dealerId: string; number: any }[] = [];
  const f = fakeRpc({
    start_staff_verification: () => [{ verification_id: 'V1', dealer_id: 'D', code: '493021', expires_at: '2026-03-10T15:10:00Z', to_address: '+15555552201', channel: 'sms', number_id: 'N', number_address: '+15555550299', provider: 'twilio', number_config: { messaging_service_sid: 'MG1' }, dealer_name: 'Gap Motors' }],
    mark_staff_verification_sent: () => null,
    confirm_staff_verification: () => [{ result: 'verified', attempts_left: 0 }],
    ...handlers,
  });
  const logs: string[] = [];
  const deps = { rpc: f.rpc, now: () => NOW, authenticate: async () => user, log: (e: string) => logs.push(e),
    dispatcher: { send: async () => ({ ok: true as const, providerMessageId: 'x' }), sendRaw: async (r: any) => { sent.push({ to: r.to, body: r.body, key: r.idempotencyKey, dealerId: r.dealerId, number: r.number }); return sendOk ? { ok: true as const, providerMessageId: 'SMv' } : { ok: false as const, error: 'provider_unavailable', retryable: true }; } } };
  const call = (body: unknown, method = 'POST') => handleStaffVerification(new Request('https://x/staff-verification', { method, body: method === 'POST' ? JSON.stringify(body) : undefined, headers: { authorization: 'Bearer jwt' } }), deps);
  return { f, call, sent, logs };
}
const IDENT = '00000000-0000-0000-0021-0000000000a5';
test('staff verification: start texts the code through the adapter and NEVER returns it to the caller', async () => {
  const h = staffHarness();
  const res = await h.call({ action: 'start', identity_id: IDENT });
  assert.equal(res.status, 200);
  const j = await res.json();
  assert.deepEqual(Object.keys(j).sort(), ['expires_at', 'ok', 'sent_to']);
  assert.ok(!JSON.stringify(j).includes('493021'));
  assert.equal(j.sent_to, maskPhone('+15555552201'));
  assert.equal(h.sent.length, 1);
  assert.deepEqual([h.sent[0].to, h.sent[0].key, h.sent[0].dealerId], ['+15555552201', 'staffcode:V1', 'D']);
  assert.equal(h.sent[0].number.config.messaging_service_sid, 'MG1');
  assert.match(h.sent[0].body, /Gap Motors: your verification code is 493021\. It expires in 10 minutes\. Do not share it\./);
  assert.equal(h.f.calls[0].args.p_actor, 'U1');
  assert.equal(h.f.calls.find((c) => c.fn === 'mark_staff_verification_sent')!.args.p_ok, true);
});
test('staff verification: a failed send is reported (502) and recorded so the cooldown lifts; the code is still not leaked', async () => {
  const h = staffHarness({}, 'U1', false);
  const res = await h.call({ action: 'start', identity_id: IDENT });
  assert.equal(res.status, 502);
  const t = await res.text();
  assert.ok(!t.includes('493021'));
  const m = h.f.calls.find((c) => c.fn === 'mark_staff_verification_sent')!.args;
  assert.deepEqual([m.p_ok, m.p_error], [false, 'provider_unavailable']);
});
test('staff verification: confirm maps results to status codes; format is checked before the database', async () => {
  const h = staffHarness({ confirm_staff_verification: (a) => [a.p_code === '111111' ? { result: 'verified', attempts_left: 0 } : { result: 'wrong_code', attempts_left: 3 }] });
  assert.equal((await h.call({ action: 'confirm', identity_id: IDENT, code: '111111' })).status, 200);
  const bad = await h.call({ action: 'confirm', identity_id: IDENT, code: '222222' });
  assert.equal(bad.status, 400);
  assert.deepEqual(await bad.json(), { result: 'wrong_code', attempts_left: 3 });
  assert.equal((await h.call({ action: 'confirm', identity_id: IDENT, code: '12ab' })).status, 400);
  assert.equal(h.f.count('confirm_staff_verification'), 2, 'malformed code never reaches the database');
  assert.equal(h.f.calls[0].args.p_actor, 'U1');
});
test('staff verification: auth + errors (401, 403, 404, 429 cooldown/rate limit, 409, bad input)', async () => {
  assert.equal((await staffHarness({}, null).call({ action: 'start', identity_id: IDENT })).status, 401);
  assert.equal((await staffHarness().call({ action: 'start', identity_id: IDENT }, 'GET')).status, 405);
  assert.equal((await staffHarness().call({ action: 'start', identity_id: 'nope' })).status, 400);
  assert.equal((await staffHarness().call({ action: 'dance', identity_id: IDENT })).status, 400);
  const err = (m: string) => staffHarness({ start_staff_verification: () => { throw new Error(`start_staff_verification: ${m}`); } });
  const cases: [string, number, string][] = [
    ['forbidden: user x lacks role', 403, 'forbidden'], ['not_found: staff identity', 404, 'not_found'], ['cooldown: wait a minute before requesting another code', 429, 'cooldown'],
    ['rate_limited: too many codes requested', 429, 'rate_limited'], ['already verified', 409, 'already_verified'], ['no_sending_number: none', 409, 'no_sending_number'], ['unsupported_channel: x', 400, 'unsupported_channel'],
  ];
  for (const [m, st, code] of cases) { const r = await err(m).call({ action: 'start', identity_id: IDENT }); assert.equal(r.status, st); assert.equal((await r.json()).error, code); }
  const unexpected = err('connection refused'); const r = await unexpected.call({ action: 'start', identity_id: IDENT });
  assert.equal(r.status, 400); assert.ok(unexpected.logs.includes('staff_verification_error'));
  assert.equal(maskPhone('+15555552201'), '+1••••••2201');
});
