import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateText, stepCountIs } from 'ai';
import { MockLanguageModelV4 } from 'ai/test';
import {
  createAgentTools, AGENT_TOOL_NAMES, sendMessageInput, updateLeadStateInput, scheduleFollowupInput, searchKnowledgeInput,
  requestHumanHandoffInput, checkInventoryInput, bookTestDriveInput, requestTradeInAppraisalInput, startPrequalInput,
  type AgentToolDeps, type AgentToolContext,
} from '../../lib/agent/tools.ts';
import { emptyEvidence } from '../../supabase/functions/_shared/before-send.ts';

const NOW = new Date('2026-11-26T15:00:00Z');
const VIN = '1HGCM82633A004352';
const calls: string[] = [];
function makeDeps(over: Partial<AgentToolDeps> = {}): AgentToolDeps {
  const rec = (n: string) => { calls.push(n); };
  return {
    proposeSend: async () => { rec('send'); return { final: 'held', holdUntil: null }; },
    updateLeadState: async () => { rec('state'); return 'applied'; },
    scheduleFollowup: async () => { rec('followup'); return { followupId: 'f1' }; },
    searchKnowledge: async () => [{ id: 'k1', title: 'Trade-in policy', kind: 'trade_in', excerpt: 'We appraise in 24h.', score: 0.91234 }],
    handoff: async () => { rec('handoff'); return { inboxItemId: 'i1' }; },
    searchInventory: async () => [{ vin: VIN, status: 'available', priceCents: 2499500, msrpCents: 2599500, year: 2023, make: 'Honda', model: 'Accord' }],
    bookTestDrive: async () => ({ status: 'confirmed', appointmentId: 'a1' }),
    requestAppraisal: async () => ({ appraisalId: 'p1', expectedResponseHours: 24 }),
    createPrequalLink: async () => ({ url: 'https://dealer.example/prequal/abc', expiresAt: '2026-11-27T15:00:00Z' }),
    recordFact: async () => { rec('fact'); return { result: 'inserted' as const, factId: 'fx1' }; },
    ...over,
  };
}
function ctx(over: Partial<AgentToolContext> = {}, deps = makeDeps()): AgentToolContext {
  return { dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence: emptyEvidence(), deps, now: () => NOW, ...over };
}
type Exec = (a: unknown, o: unknown) => Promise<any>;
const run = (t: { execute?: unknown }, args: unknown) => (t.execute as Exec)(args, { toolCallId: 't', messages: [] });

test('exactly the ten specified tools exist', () => {
  assert.deepEqual(Object.keys(createAgentTools(ctx())).sort(), [...AGENT_TOOL_NAMES].sort());
  assert.equal(AGENT_TOOL_NAMES.length, 10);
});

test('every input schema is strict: unknown / tenant keys are rejected', () => {
  const schemas = { sendMessageInput, updateLeadStateInput, scheduleFollowupInput, searchKnowledgeInput, requestHumanHandoffInput, checkInventoryInput, bookTestDriveInput, requestTradeInAppraisalInput, startPrequalInput };
  const valid: Record<string, unknown> = {
    sendMessageInput: { body: 'Hello' },
    updateLeadStateInput: { stage: 'qualified', confidence: 0.8, reason: 'wants to drive it', evidence_quote: 'can I test drive it' },
    scheduleFollowupInput: { when: '2026-11-27T15:00:00-05:00', reason: 'check back' },
    searchKnowledgeInput: { query: 'trade in policy' },
    requestHumanHandoffInput: { reason: 'negotiation', summary: 'Customer wants a better price.' },
    checkInventoryInput: { make: 'Honda' },
    bookTestDriveInput: { vin: VIN, slot_start: '2026-11-27T15:00:00-05:00' },
    requestTradeInAppraisalInput: { year: 2019, make: 'Ford', model: 'F-150', mileage: 60000, condition: 'good' },
    startPrequalInput: {},
  };
  for (const [name, schema] of Object.entries(schemas)) {
    assert.ok(schema.safeParse(valid[name]).success, `${name} accepts valid input`);
    for (const forged of ['dealer_id', 'lead_id', 'contact_id', 'run_id', '__proto__']) {
      const bad = JSON.parse(`{"${forged}":"x"}`) as object;
      assert.ok(!schema.safeParse({ ...(valid[name] as object), ...bad }).success, `${name} rejects ${forged}`);
    }
  }
});

test('schema edge cases: VIN, empty inventory filter, SSN-like fields are impossible, prequal takes no PII', () => {
  assert.ok(!bookTestDriveInput.safeParse({ vin: 'IOQ00000000000000', slot_start: '2026-11-27T15:00:00-05:00' }).success);
  assert.ok(!bookTestDriveInput.safeParse({ vin: VIN, slot_start: 'tomorrow at 3' }).success);
  assert.ok(!checkInventoryInput.safeParse({}).success);
  assert.ok(!checkInventoryInput.safeParse({ make: 'Honda', limit: 50 }).success);
  assert.ok(!startPrequalInput.safeParse({ ssn: '123-45-6789' }).success);
  assert.ok(!startPrequalInput.safeParse({ dob: '1990-01-01' }).success);
  assert.equal(bookTestDriveInput.parse({ vin: VIN.toLowerCase(), slot_start: '2026-11-27T15:00:00-05:00' }).vin, VIN);
  assert.equal(searchKnowledgeInput.parse({ query: 'abc' }).top_k, 4);
});

test('forged dealer_id through the real AI SDK loop => tool-error, execute never runs', async () => {
  calls.length = 0;
  let n = 0;
  const usage = { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } };
  const model = new MockLanguageModelV4({
    doGenerate: async () => (++n === 1
      ? { content: [{ type: 'tool-call', toolCallId: 'c1', toolName: 'send_message', input: JSON.stringify({ body: 'hi', dealer_id: 'other-tenant' }) }], finishReason: { unified: 'tool-calls', raw: 'tool_calls' }, usage, warnings: [] }
      : { content: [{ type: 'text', text: 'ignored free text' }], finishReason: { unified: 'stop', raw: 'stop' }, usage, warnings: [] }),
  });
  const r = await generateText({ model, tools: createAgentTools(ctx()), prompt: 'x', stopWhen: stepCountIs(3) });
  assert.ok(r.steps[0]!.content.some((c) => c.type === 'tool-error'));
  assert.deepEqual(calls, []);
});

test('send_message: held / delayed / sent are ok; retry-able veto teaches; handoff veto locks the thread', async () => {
  const c = ctx({}, makeDeps({ proposeSend: async () => ({ final: 'vetoed', code: 'unverified_price', reason: 'Call check_inventory first.', action: 'retry' }) }));
  const t = createAgentTools(c);
  const r1 = await run(t.send_message, { body: 'It is $1' });
  assert.deepEqual([r1.ok, r1.error.code, r1.error.retryable], [false, 'unverified_price', true]);

  const c2 = ctx({}, makeDeps({ proposeSend: async () => ({ final: 'vetoed', code: 'inbound_stop', reason: 'Opt-out.', action: 'handoff' }) }));
  const t2 = createAgentTools(c2);
  const r2 = await run(t2.send_message, { body: 'hi' });
  assert.match(r2.error.message, /request_human_handoff/);
  const r3 = await run(t2.send_message, { body: 'hi again' });
  assert.equal(r3.error.code, 'handed_off');

  const t3 = createAgentTools(ctx());
  const h = await run(t3.send_message, { body: 'hello' });
  assert.deepEqual([h.ok, h.status], [true, 'held']);
});

test('send_message limits: 3 attempts per turn, 2 queued messages per turn', async () => {
  const t = createAgentTools(ctx({}, makeDeps({ proposeSend: async () => ({ final: 'vetoed', code: 'x', reason: 'r', action: 'retry' }) })));
  for (let i = 0; i < 3; i++) await run(t.send_message, { body: `try ${i}` });
  assert.equal((await run(t.send_message, { body: 'again' })).error.code, 'too_many_retries');
  const t2 = createAgentTools(ctx());
  await run(t2.send_message, { body: 'one' }); await run(t2.send_message, { body: 'two' });
  assert.equal((await run(t2.send_message, { body: 'three' })).error.code, 'turn_message_limit');
});

test('handoff silences later sends', async () => {
  const t = createAgentTools(ctx());
  assert.equal((await run(t.request_human_handoff, { reason: 'unsure', summary: 'Not sure what they want.', urgency: 'normal' })).ok, true);
  assert.equal((await run(t.send_message, { body: 'x' })).error.code, 'handed_off');
});

test('schedule_followup validates the window', async () => {
  const t = createAgentTools(ctx());
  assert.equal((await run(t.schedule_followup, { when: '2026-11-26T15:05:00Z', reason: 'soon' })).error.code, 'followup_too_soon');
  assert.equal((await run(t.schedule_followup, { when: '2027-02-01T15:00:00Z', reason: 'far' })).error.code, 'followup_too_far');
  assert.equal((await run(t.schedule_followup, { when: '2026-11-27T15:00:00Z', reason: 'ok' })).ok, true);
});

test('check_inventory fills the evidence the gates trust; no match teaches', async () => {
  const c = ctx(); const t = createAgentTools(c);
  const r = await run(t.check_inventory, { make: 'Honda', limit: 3 });
  assert.equal(r.ok, true);
  assert.equal(c.evidence.vehicles[0]!.priceCents, 2499500);
  const none = createAgentTools(ctx({}, makeDeps({ searchInventory: async () => [] })));
  assert.equal((await run(none.check_inventory, { make: 'Edsel', limit: 3 })).error.code, 'no_match');
});

test('book_test_drive: too-soon rejected, unavailable returns alternatives, success records appointment evidence', async () => {
  const c = ctx(); const t = createAgentTools(c);
  assert.equal((await run(t.book_test_drive, { vin: VIN, slot_start: '2026-11-26T15:30:00Z', duration_min: 30 })).error.code, 'slot_too_soon');
  assert.equal((await run(t.book_test_drive, { vin: VIN, slot_start: '2026-11-27T20:00:00Z', duration_min: 30 })).status, 'confirmed');
  assert.equal(c.evidence.appointments.length, 1);
  const un = createAgentTools(ctx({}, makeDeps({ bookTestDrive: async () => ({ status: 'unavailable', reason: 'Closed.', alternatives: ['10am'] }) })));
  const r = await run(un.book_test_drive, { vin: VIN, slot_start: '2026-11-27T20:00:00Z', duration_min: 30 });
  assert.match(r.error.message, /10am/);
});

test('deps that throw become teaching errors, never exceptions', async () => {
  const t = createAgentTools(ctx({}, makeDeps({ searchKnowledge: async () => { throw new Error('db down'); } })));
  const r = await run(t.search_knowledge, { query: 'trade in', top_k: 4 });
  assert.deepEqual([r.ok, r.error.code], [false, 'tool_failed']);
});

test('trade-in and prequal tools never expose values or PII', async () => {
  const t = createAgentTools(ctx());
  const a = await run(t.request_trade_in_appraisal, { year: 2019, make: 'Ford', model: 'F-150', mileage: 60000, condition: 'good' });
  assert.match(a.note, /Do not state any trade value/);
  const p = await run(t.start_prequal, {});
  assert.match(p.url, /^https:\/\//);
  assert.match(p.note, /Do not mention approval/);
});
