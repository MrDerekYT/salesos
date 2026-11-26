import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sweep, followupTemplate, outcomeForDecision, type DueDraft, type DuePlan, type SweeperDeps, type ProviderResult } from '../../supabase/functions/outbound-sweeper/process.ts';
import { gateInputFromContext, type GateContextRow } from '../../supabase/functions/_shared/gate-context.ts';
import type { ComplianceDecision, GateInput, VehicleEvidence } from '../../supabase/functions/_shared/before-send.ts';

const NOW = new Date('2026-11-26T16:00:00Z');
const VEH: VehicleEvidence = { vin: '1HGCV1F30LA160001', status: 'available', priceCents: 2800000, year: 2022, make: 'Honda', model: 'Accord' };
function ctxRow(o: { settings?: Partial<GateContextRow['settings']>; dnc?: boolean; lead?: Partial<NonNullable<GateContextRow['lead']>>; priorAi?: number } = {}): GateContextRow {
  return {
    dealer_name: 'Follow Motors', contact: { id: 'C', dnc_open: !!o.dnc },
    lead: { id: 'L', stage: 'qualifying', force_human: false, bot_silenced_until: null, context_version: 4, ai_replies_since_inbound: 3, ...o.lead },
    latest_inbound: { id: 'M', body: 'old message from last week', at: '2026-11-19T15:00:00Z', channel: 'sms' },
    thread: { prior_ai_messages: o.priorAi ?? 2, prior_outbound_on_channel: 3 },
    budget: { cap_cents: 10000, spent_cents: 10, hard_stop: true },
    settings: { ai_disclosure_text: "I'm {dealer}'s virtual assistant.", stop_footer_text: 'Reply STOP to opt out.', rep_hold_minutes: 2, followup_hold_minutes: 0,
      auto_send_enabled: true, auto_send_kinds: ['reply', 'followup'], ai_max_unanswered_replies: 2, followup_handoff_hours: 24, ...o.settings },
  };
}
const allow = (commit: boolean): ComplianceDecision => ({ verdict: 'allow', code: 'ok', reason: 'ok', not_before: null, reservation_id: commit ? 'R1' : null });
const plan = (o: Partial<DuePlan> = {}): DuePlan => ({ id: 'P1', dealer_id: 'D', lead_id: 'L', contact_id: 'C', trigger_kind: 'stalled', purpose: 'conversational', channel: null, vehicle_id: null, attempts: 0, context: {}, ...o });

interface Rec { outcomes: [string, string, string | null, string | null, string | null][]; drafts: any[]; sends: string[]; finals: [string, boolean][]; status: [string, string, any][]; canSend: GateInput[] }
function fake(o: Partial<SweeperDeps> & { ctx?: GateContextRow; plans?: DuePlan[]; drafts?: DueDraft[]; compliance?: (i: GateInput, commit: boolean) => ComplianceDecision; provider?: ProviderResult; vehicle?: VehicleEvidence | null } = {}) {
  const rec: Rec = { outcomes: [], drafts: [], sends: [], finals: [], status: [], canSend: [] };
  const deps: SweeperDeps = {
    now: () => NOW,
    claimDrafts: async () => o.drafts ?? [],
    releaseFacts: async () => ({ leadContextVersion: 4, leadForceHuman: false, openInboxForLead: false, autoSendEnabled: true, handoffHours: 24 }),
    setDraftStatus: async (id, s, p) => { rec.status.push([id, s, p]); },
    gateContext: async () => o.ctx ?? ctxRow(),
    canSend: async (_t, i, commit) => { rec.canSend.push(i); return (o.compliance ?? ((_, c) => allow(c)))(i, commit); },
    providerSend: async (a) => { rec.sends.push(a.body); return o.provider ?? { ok: true, providerMessageId: 'pm1' }; },
    finalize: async (id, r) => { rec.finals.push([id, r.ok]); },
    claimFollowups: async () => o.plans ?? [],
    pickRoute: async () => ({ channel: 'sms', numberId: 'N' }),
    followupFacts: async () => ({ firstName: 'Ann', vehicle: o.vehicle === undefined ? null : o.vehicle }),
    insertDraft: async (a) => { rec.drafts.push(a); return `DR${rec.drafts.length}`; },
    recordOutcome: async (id, out, code, nb, dr) => { rec.outcomes.push([id, out, code, nb, dr]); return ({ sent: 'sent', drafted: 'drafted', delayed: 'postponed', retry: 'postponed', stop: 'cancelled' } as const)[out]; },
    ...o,
  };
  return { deps, rec };
}

test('gate context maps every GateInput field; proactive sends ignore the stale inbound', () => {
  const g = gateInputFromContext(ctxRow({ dnc: true }), { actor: 'ai', channel: 'sms', purpose: 'marketing', kind: 'followup', body: 'hi', now: NOW, inboundText: null, estimateCents: 3 });
  assert.equal(g.inboundText, null);
  assert.equal(g.contact.dncOpen, true);
  assert.deepEqual(g.budget, { capCents: 10000, spentCents: 10, estimateCents: 3, hardStop: true });
  assert.equal(g.settings.dealerName, 'Follow Motors');
  assert.equal(g.lead.aiRepliesSinceInbound, 3);
  const r = gateInputFromContext(ctxRow(), { actor: 'ai', channel: 'sms', purpose: 'conversational', kind: 'reply', body: 'x', now: NOW });
  assert.equal(r.inboundText, 'old message from last week');
  assert.throws(() => gateInputFromContext(null as unknown as GateContextRow, { actor: 'ai', channel: 'sms', purpose: 'conversational', kind: 'reply', body: 'x', now: NOW }), /gate context missing/);
});

test('templates use only evidence; price_drop needs a priced, available vehicle', () => {
  const f = { firstName: 'Ann', vehicle: VEH, dealerName: 'Follow Motors' };
  assert.match(followupTemplate(plan({ trigger_kind: 'price_drop' }), f)!, /2022 Honda Accord .* now \$28,000/);
  assert.equal(followupTemplate(plan({ trigger_kind: 'price_drop' }), { ...f, vehicle: { ...VEH, status: 'sold' } }), null);
  assert.match(followupTemplate(plan({ trigger_kind: 'promised', context: { reason: 'check incoming Accords.' } }), f)!, /as promised on check incoming Accords\./);
  assert.match(followupTemplate(plan({ trigger_kind: 'service_due', context: { year: 2021, make: 'Honda', model: 'CR-V' } }), f)!, /2021 Honda CR-V is coming due/);
  for (const k of ['stalled', 'test_drive_noshow', 'lease_end'] as const) assert.ok(followupTemplate(plan({ trigger_kind: k }), f)!.startsWith('Hi Ann'));
});

test('outcome mapping: send/hold/delay; consent/DNC/human-owned stop; content vetoes retry', () => {
  assert.equal(outcomeForDecision('send', 'ok'), 'sent');
  assert.equal(outcomeForDecision('hold', 'rep_hold'), 'drafted');
  assert.equal(outcomeForDecision('delay', 'quiet_hours'), 'delayed');
  assert.equal(outcomeForDecision('veto', 'no_consent', 'drop'), 'stop');
  assert.equal(outcomeForDecision('veto', 'dnc_active', 'drop'), 'stop');
  assert.equal(outcomeForDecision('veto', 'unverified_price', 'retry'), 'retry');
  assert.equal(outcomeForDecision('veto', 'template_repetition', 'retry'), 'retry');
});

test('price-drop follow-up: passes the price gate on evidence, reserves, sends, finalizes, records sent', async () => {
  const { deps, rec } = fake({ plans: [plan({ trigger_kind: 'price_drop', purpose: 'marketing', vehicle_id: 'V' })], vehicle: VEH });
  const s = await sweep(deps);
  assert.equal(s.followups.sent, 1);
  assert.match(rec.sends[0], /\$28,000/);
  assert.match(rec.sends[0], /Reply STOP to opt out\./);          // marketing => STOP footer appended by the chain
  assert.deepEqual(rec.drafts[0].status, 'sending');
  assert.equal(rec.drafts[0].reservationId, 'R1');
  assert.deepEqual(rec.finals, [['DR1', true]]);
  assert.deepEqual(rec.outcomes[0].slice(1, 3), ['sent', 'ok']);
  assert.equal(rec.canSend.filter((i) => i.purpose === 'marketing' && i.kind === 'followup').length, 2);   // dry run + commit
});

test('quiet hours from can_send => postponed with not_before (never dropped)', async () => {
  const { deps, rec } = fake({ plans: [plan()], compliance: () => ({ verdict: 'delay', code: 'quiet_hours', reason: 'q', not_before: '2026-11-27T13:00:00Z', reservation_id: null }) });
  const s = await sweep(deps);
  assert.equal(s.followups.postponed, 1);
  assert.deepEqual(rec.outcomes[0].slice(1, 4), ['delayed', 'quiet_hours', '2026-11-27T13:00:00Z']);
  assert.equal(rec.sends.length, 0);
});

test('no consent / DNC => stop; force_human => stop; unreachable => stop', async () => {
  const a = fake({ plans: [plan({ purpose: 'marketing', trigger_kind: 'lease_end' })], compliance: () => ({ verdict: 'veto', code: 'no_consent', reason: 'n', not_before: null, reservation_id: null }) });
  await sweep(a.deps); assert.deepEqual(a.rec.outcomes[0].slice(1, 3), ['stop', 'no_consent']);
  const b = fake({ plans: [plan()], ctx: ctxRow({ dnc: true }) });
  await sweep(b.deps); assert.deepEqual(b.rec.outcomes[0].slice(1, 3), ['stop', 'dnc_active']);
  const c = fake({ plans: [plan()], ctx: ctxRow({ lead: { force_human: true } }) });
  await sweep(c.deps); assert.deepEqual(c.rec.outcomes[0].slice(1, 3), ['stop', 'human_owned']);
  const d = fake({ plans: [plan()], pickRoute: async () => null });
  await sweep(d.deps); assert.deepEqual(d.rec.outcomes[0].slice(1, 3), ['stop', 'unreachable']);
});

test('auto-send off => held draft for a rep, plan drafted; follow-up hold => held with release time', async () => {
  const a = fake({ plans: [plan()], ctx: ctxRow({ settings: { auto_send_enabled: false } }) });
  const s = await sweep(a.deps);
  assert.equal(s.followups.drafted, 1);
  assert.equal(a.rec.drafts[0].status, 'awaiting_review');
  assert.deepEqual(a.rec.outcomes[0].slice(1, 3), ['drafted', 'needs_approval']);
  const b = fake({ plans: [plan()], ctx: ctxRow({ settings: { followup_hold_minutes: 10 } }) });
  await sweep(b.deps);
  assert.equal(b.rec.drafts[0].status, 'held');
  assert.equal(b.rec.drafts[0].releaseAt, '2026-11-26T16:10:00.000Z');
});

test('LLM wording with an unverified price falls back to the template; template-less failure retries', async () => {
  const { deps, rec } = fake({ plans: [plan({ trigger_kind: 'price_drop', purpose: 'marketing' })], vehicle: VEH, composeWithLlm: async () => 'Great news Ann, it is now just $19,999!' });
  await sweep(deps);
  assert.equal(rec.sends.length, 1);
  assert.match(rec.sends[0], /\$28,000/);
  assert.doesNotMatch(rec.sends[0], /19,999/);
  const sold = fake({ plans: [plan({ trigger_kind: 'price_drop', purpose: 'marketing' })], vehicle: { ...VEH, status: 'sold' } });
  await sweep(sold.deps);
  assert.deepEqual(sold.rec.outcomes[0].slice(1, 3), ['stop', 'vehicle_unavailable']);
});

test('provider failure releases via finalize and retries; exceptions retry, never lose the plan', async () => {
  const a = fake({ plans: [plan()], provider: { ok: false, error: '30007 carrier filtered', retryable: true } });
  await sweep(a.deps);
  assert.deepEqual(a.rec.finals, [['DR1', false]]);
  assert.deepEqual(a.rec.outcomes[0].slice(1, 3), ['retry', 'provider_error']);
  const b = fake({ plans: [plan()], gateContext: async () => { throw new Error('db down'); } });
  const s = await sweep(b.deps);
  assert.equal(s.followups.errors, 1);
  assert.deepEqual(b.rec.outcomes[0].slice(1, 3), ['retry', 'sweeper_error']);
});

const R0 = ctxRow({ lead: { ai_replies_since_inbound: 0 } });   // the customer wrote last
const draft = (o: Partial<DueDraft> = {}): DueDraft => ({ id: 'X1', dealer_id: 'D', lead_id: 'L', contact_id: 'C', channel: 'sms', number_id: 'N', actor: 'ai', purpose: 'conversational', kind: 'reply',
  body_ai: 'Happy to help, what time works?', body_edited: null, evidence: null, status: 'sending', release_at: '2026-11-26T15:58:00Z', created_at: '2026-11-26T15:56:00Z', expected_context_version: 4, ...o });

test('held draft: chain re-runs with holdElapsed, reserves under the lock, sends, finalizes', async () => {
  const { deps, rec } = fake({ ctx: R0, drafts: [draft()] });
  const s = await sweep(deps);
  assert.equal(s.drafts.sent, 1);
  assert.ok(rec.canSend.every((i) => i.holdElapsed));
  assert.deepEqual(rec.status[0].slice(0, 2), ['X1', 'sending']);
  assert.equal(rec.status[0][2].reservationId, 'R1');
  assert.deepEqual(rec.finals, [['X1', true]]);
});

test('held draft: stale context / new inbox item => handed to rep; not due => back to held; rep edit wins', async () => {
  const a = fake({ ctx: R0, drafts: [draft({ expected_context_version: 3 })] });
  await sweep(a.deps); assert.deepEqual(a.rec.status[0].slice(1), ['handed_to_rep', { vetoCode: 'stale_context' }]);
  const b = fake({ ctx: R0, drafts: [draft()], releaseFacts: async () => ({ leadContextVersion: 4, leadForceHuman: false, openInboxForLead: true, autoSendEnabled: true, handoffHours: 24 }) });
  await sweep(b.deps); assert.equal(b.rec.status[0][1], 'handed_to_rep');
  const c = fake({ ctx: R0, drafts: [draft({ release_at: '2026-11-26T16:30:00Z' })] });
  await sweep(c.deps); assert.equal(c.rec.status[0][1], 'held');
  const d = fake({ ctx: R0, drafts: [draft({ body_edited: 'Rep wording here.' })] });
  await sweep(d.deps); assert.match(d.rec.sends[0], /^Rep wording here\./);
});

test('held draft: daily cap => delayed with not_before; content veto => vetoed', async () => {
  const a = fake({ ctx: R0, drafts: [draft()], compliance: () => ({ verdict: 'delay', code: 'daily_cap', reason: 'cap', not_before: '2026-11-27T14:00:00Z', reservation_id: null }) });
  await sweep(a.deps); assert.deepEqual(a.rec.status[0].slice(1), ['delayed', { releaseAt: '2026-11-27T14:00:00Z', vetoCode: 'daily_cap' }]);
  const b = fake({ ctx: R0, drafts: [draft({ body_ai: 'It is $12,345 today.' })] });
  await sweep(b.deps); assert.deepEqual(b.rec.status[0].slice(1), ['vetoed', { vetoCode: 'unverified_price' }]);
});

test('held AI reply after the customer went quiet hits the reply cap => vetoed, not sent', async () => {
  const { deps, rec } = fake({ drafts: [draft()] });   // fixture: 3 AI messages since the last inbound
  await sweep(deps);
  assert.deepEqual(rec.status[0].slice(1), ['vetoed', { vetoCode: 'ai_reply_cap' }]);
  assert.equal(rec.sends.length, 0);
});
