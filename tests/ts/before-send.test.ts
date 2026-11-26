import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  BEFORE_SEND_GATES, DEFAULT_GATES, emptyEvidence, runChain, decideSend, releaseVerdict, humanDelayMs,
  moneyAmountsCents, financialPercents,
  type GateInput, type ComplianceDecision, type SendDeps, type ReleaseCandidate,
} from '../../supabase/functions/_shared/before-send.ts';

const NOW = new Date('2026-11-26T15:00:00Z');
const ALLOW_C: ComplianceDecision = { verdict: 'allow', code: 'ok', reason: 'ok', not_before: null, reservation_id: null };

function input(over: Partial<GateInput> = {}): GateInput {
  return {
    actor: 'ai', channel: 'sms', purpose: 'conversational', kind: 'reply', body: 'Happy to help. What time works for a visit?', now: NOW,
    inboundText: 'Can I come look at it?', contact: { id: 'c1', dncOpen: false },
    lead: { forceHuman: false, botSilencedUntil: null, aiRepliesSinceInbound: 0 },
    budget: { capCents: null, spentCents: 0, estimateCents: 5, hardStop: false },
    settings: { dealerName: 'Acme Motors', aiDisclosureText: 'This is {dealer}\'s virtual assistant.', stopFooterText: 'Reply STOP to opt out.', repHoldMinutes: 15, followupHoldMinutes: 0, autoSendEnabled: false, autoSendKinds: [], aiMaxUnansweredReplies: 2 },
    thread: { priorAiMessages: 3, priorOutboundToContactOnChannel: 3 },
    evidence: emptyEvidence(), compliance: null, holdElapsed: false,
    ...over,
  };
}
const deps = (c: ComplianceDecision = ALLOW_C) => ({ canSendDryRun: async () => c });
const code = (r: { verdict: string } & Record<string, unknown>) => (r.verdict === 'allow' ? 'allow' : String(r.code));

test('gate order is locked (changing it is a version bump, not a refactor)', () => {
  assert.deepEqual([...BEFORE_SEND_GATES], ['opt_out', 'human_owned', 'ai_budget', 'ai_reply_cap', 'compliance', 'sensitive_data', 'internal_leak', 'escalation_topics', 'price_apr_promise', 'in_stock_claim', 'appointment_claim', 'disclosure', 'rep_hold']);
  assert.deepEqual(DEFAULT_GATES.map((g) => g.id).filter(Boolean), [...BEFORE_SEND_GATES]);
});

test('clean reply with auto-send off is held for approval', async () => {
  const o = await runChain(input(), deps());
  assert.equal(o.result.verdict, 'hold');
  assert.equal(code(o.result), 'needs_approval');
  assert.ok(o.traces.length >= 10);
});

test('opt-out in the inbound text vetoes with handoff before anything else', async () => {
  const o = await runChain(input({ inboundText: 'STOP' }), deps());
  assert.equal(o.result.verdict, 'veto');
  assert.equal(o.traces[0]?.gate, 'opt_out');
  assert.equal(o.traces.length, 1, 'chain short-circuits on the first non-allow');
});

test('open DNC is a hard drop; human-owned lead is a drop', async () => {
  const a = await runChain(input({ contact: { id: 'c1', dncOpen: true } }), deps());
  assert.equal(code(a.result), 'dnc_active');
  const b = await runChain(input({ lead: { forceHuman: true, botSilencedUntil: null, aiRepliesSinceInbound: 0 } }), deps());
  assert.equal(code(b.result), 'human_owned');
});

test('reply cap and AI budget', async () => {
  const a = await runChain(input({ lead: { forceHuman: false, botSilencedUntil: null, aiRepliesSinceInbound: 2 } }), deps());
  assert.equal(code(a.result), 'ai_reply_cap');
  const b = await runChain(input({ budget: { capCents: 100, spentCents: 99, estimateCents: 5, hardStop: true } }), deps());
  assert.equal(code(b.result), 'ai_budget_exceeded');
});

test('SQL compliance verdicts map: delay stays a delay, veto is a drop, repetition is retryable', async () => {
  const d = await runChain(input(), deps({ ...ALLOW_C, verdict: 'delay', code: 'quiet_hours', reason: 'quiet', not_before: '2026-11-27T13:00:00Z' }));
  assert.equal(d.result.verdict, 'delay');
  const v = await runChain(input(), deps({ ...ALLOW_C, verdict: 'veto', code: 'no_consent', reason: 'no consent' }));
  assert.equal(v.result.verdict === 'veto' && v.result.action, 'drop');
  const r = await runChain(input(), deps({ ...ALLOW_C, verdict: 'veto', code: 'template_repetition', reason: 'rep' }));
  assert.equal(r.result.verdict === 'veto' && r.result.action, 'retry');
});

test('sensitive / escalation topics in the inbound hand off', async () => {
  for (const t of ['my SSN is 123-45-6789', 'I want to talk to my attorney about this', 'can you lower the price if I pay cash', 'I want to speak to a manager']) {
    const o = await runChain(input({ inboundText: t }), deps());
    assert.equal(o.result.verdict, 'veto', t);
  }
});

test('price/APR gate trusts only tool evidence', async () => {
  const no = await runChain(input({ body: 'That one is $24,995 today.' }), deps());
  assert.equal(code(no.result), 'unverified_price');
  const ev = { ...emptyEvidence(), vehicles: [{ vin: '1HGCM82633A004352', status: 'available' as const, priceCents: 2499500, year: 2023, make: 'Honda', model: 'Accord' }] };
  const yes = await runChain(input({ body: 'The Accord is $24,995.', evidence: ev }), deps());
  assert.notEqual(code(yes.result), 'unverified_price');
  const g = await runChain(input({ body: 'You\'re approved, guaranteed approval!' }), deps());
  assert.equal(code(g.result), 'financing_guarantee');
  const apr = await runChain(input({ body: 'We can do 3.9% APR on that.' }), deps());
  assert.equal(code(apr.result), 'unverified_apr');
});

test('in-stock gate: no claim without inventory evidence, none for sold units', async () => {
  const a = await runChain(input({ body: 'Yes, the Camry is still available!' }), deps());
  assert.equal(code(a.result), 'unverified_availability');
  const ev = { ...emptyEvidence(), vehicles: [{ vin: '4T1BF1FK5CU123456', status: 'sold' as const, year: 2022, make: 'Toyota', model: 'Camry' }] };
  const b = await runChain(input({ body: 'The Camry is in stock and ready to drive.', evidence: ev }), deps());
  assert.equal(code(b.result), 'availability_contradiction');
  const c = await runChain(input({ body: 'We have times available tomorrow, what works?' }), deps());
  assert.notEqual(code(c.result), 'unverified_availability');
  const d = await runChain(input({ body: 'VIN 1HGCM82633A004352 is yours.' }), deps());
  assert.equal(code(d.result), 'unverified_vin');
});

test('appointment gate: "confirmed" needs a confirmed booking', async () => {
  const a = await runChain(input({ body: 'You\'re confirmed for 3pm tomorrow.' }), deps());
  assert.equal(code(a.result), 'unverified_appointment');
  const ev = { ...emptyEvidence(), appointments: [{ startsAt: '2026-11-27T20:00:00Z', status: 'requested' as const }] };
  const b = await runChain(input({ body: 'You\'re confirmed for 3pm tomorrow.', evidence: ev }), deps());
  assert.equal(code(b.result), 'appointment_not_confirmed');
});

test('disclosure + STOP footer are appended to first AI message only', async () => {
  const first = await runChain(input({ thread: { priorAiMessages: 0, priorOutboundToContactOnChannel: 0 } }), deps());
  assert.match(first.body, /virtual assistant/);
  assert.match(first.body, /Reply STOP/);
  assert.match(first.body, /Acme Motors/);
  const later = await runChain(input(), deps());
  assert.equal(later.body, input().body);
});

test('rep hold: auto-send on => 15 min hold for replies, followups pass at 0 min, cold always needs approval', async () => {
  const s = { ...input().settings, autoSendEnabled: true, autoSendKinds: ['reply', 'followup', 'cold'] as GateInput['settings']['autoSendKinds'] };
  const r = await runChain(input({ settings: s }), deps());
  assert.equal(r.result.verdict === 'hold' && r.result.holdUntil, new Date(NOW.getTime() + 15 * 60_000).toISOString());
  const f = await runChain(input({ settings: s, kind: 'followup' }), deps());
  assert.equal(f.result.verdict, 'allow');
  const c = await runChain(input({ settings: s, kind: 'cold' }), deps());
  assert.equal(code(c.result), 'needs_approval');
  const done = await runChain(input({ settings: s, holdElapsed: true }), deps());
  assert.equal(done.result.verdict, 'allow');
});

test('decideSend: commit happens only after the chain allows; a lost race becomes a delay', async () => {
  let commits = 0;
  const s = { ...input().settings, autoSendEnabled: true, autoSendKinds: ['followup'] as GateInput['settings']['autoSendKinds'] };
  const base: Omit<SendDeps, 'canSendCommit'> = deps();
  const ok = await decideSend(input({ settings: s, kind: 'followup' }), { ...base, canSendCommit: async () => { commits++; return { ...ALLOW_C, reservation_id: 'r1' }; } });
  assert.equal(ok.final, 'send');
  assert.equal(commits, 1);
  const vetoed = await decideSend(input({ body: 'Only $1 today' }), { ...base, canSendCommit: async () => { commits++; return ALLOW_C; } });
  assert.equal(vetoed.final, 'veto');
  assert.equal(commits, 1, 'content veto never burns a cap slot');
  const held = await decideSend(input(), { ...base, canSendCommit: async () => { commits++; return ALLOW_C; } });
  assert.equal(held.final, 'hold');
  assert.equal(commits, 1);
  const race = await decideSend(input({ settings: s, kind: 'followup' }), { ...base, canSendCommit: async () => ({ ...ALLOW_C, verdict: 'delay', code: 'daily_cap', not_before: '2026-11-27T13:00:00Z', reservation_id: null }) });
  assert.equal(race.final, 'delay');
});

test('releaseVerdict hands stale or unconfirmed drafts to a rep', () => {
  const base: ReleaseCandidate = {
    status: 'held', releaseAt: new Date(NOW.getTime() - 1000).toISOString(), createdAt: new Date(NOW.getTime() - 20 * 60_000).toISOString(), kind: 'reply',
    expectedContextVersion: 3, leadContextVersion: 3, leadForceHuman: false, openInboxForLead: false, autoSendEnabled: true, handoffHours: 48,
  };
  assert.equal(releaseVerdict(base, NOW).verdict, 'send');
  assert.deepEqual(releaseVerdict({ ...base, leadContextVersion: 4 }, NOW), { verdict: 'hand_to_rep', reason: 'stale_context' });
  assert.deepEqual(releaseVerdict({ ...base, autoSendEnabled: false }, NOW), { verdict: 'hand_to_rep', reason: 'auto_send_off' });
  assert.deepEqual(releaseVerdict({ ...base, createdAt: new Date(NOW.getTime() - 49 * 3_600_000).toISOString() }, NOW), { verdict: 'hand_to_rep', reason: 'not_sent_in_window' });
  assert.equal(releaseVerdict({ ...base, releaseAt: new Date(NOW.getTime() + 60_000).toISOString() }, NOW).verdict, 'wait');
  assert.equal(releaseVerdict({ ...base, openInboxForLead: true }, NOW).verdict, 'hand_to_rep');
});

test('helpers', () => {
  assert.deepEqual(moneyAmountsCents('$24,995 or $199.50/mo or 25k bucks'), [2499500, 19950]);
  assert.deepEqual(financialPercents('3.9% APR; 50% off floor mats'), [3.9]);
  assert.equal(humanDelayMs(0), 1200);
  assert.equal(humanDelayMs(10_000), 7500);
});
