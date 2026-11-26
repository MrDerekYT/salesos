import { test } from 'node:test';
import assert from 'node:assert/strict';
import { processBriefings, fallbackNarrative, isGrounded, validateNarration, DEFAULT_BRIEFING_CONFIG, type BriefingDeps, type BriefingItemRow, type ClaimedBriefing } from '../../supabase/functions/morning-briefing/process.ts';
import { emptyEvidence, type GateInput, type ComplianceDecision } from '../../supabase/functions/_shared/before-send.ts';

const NOW = new Date('2026-11-26T11:30:00Z');
const FACTS = { total_candidates: 7, by_kind: { waiting_reply: 3, test_drive_today: 1, hot_gone_quiet: 3 }, size: 2 };
const B: ClaimedBriefing = { id: 'b1', dealer_id: 'd', user_id: 'u', local_date: '2026-11-26', attempts: 1 };
const item = (rank: number, kind: BriefingItemRow['kind'], reason: string): BriefingItemRow => ({ id: `i${rank}`, rank, lead_id: `l${rank}`, kind, score: 1 - rank / 10, reason_text: reason, evidence: { contact_reachable: true } });
const ITEMS = [item(1, 'waiting_reply', 'Replied 2h ago and is still waiting'), item(2, 'test_drive_today', 'Test drive at 2:00 PM')];
const OK: ComplianceDecision = { verdict: 'allow', code: 'ok', reason: 'ok', not_before: null, reservation_id: null };

function gate(over: Partial<GateInput> = {}): GateInput {
  return {
    actor: 'ai', channel: 'sms', purpose: 'conversational', kind: 'reply', body: 'x', now: NOW, inboundText: 'is it available?', contact: { id: 'c', dncOpen: false },
    lead: { forceHuman: false, botSilencedUntil: null, aiRepliesSinceInbound: 0 }, budget: { capCents: null, spentCents: 0, estimateCents: 1, hardStop: false },
    settings: { dealerName: 'Acme', aiDisclosureText: '', stopFooterText: '', repHoldMinutes: 15, followupHoldMinutes: 0, autoSendEnabled: false, autoSendKinds: [], aiMaxUnansweredReplies: 2 },
    thread: { priorAiMessages: 2, priorOutboundToContactOnChannel: 2 }, evidence: emptyEvidence(), compliance: null, holdElapsed: false, ...over,
  };
}
function deps(over: Partial<BriefingDeps> = {}) {
  const log = { drafts: [] as string[], saved: null as null | { narrative: string }, delivered: 0, failed: [] as string[], marked: 0, links: [] as string[] };
  const d: BriefingDeps = {
    claim: async () => [B],
    build: async () => ({ items: ITEMS, facts: FACTS }),
    narrate: async () => ({ narrative: 'Good morning. 3 replies waiting, 1 test drive today and 3 hot leads gone quiet.' }),
    draftReply: async () => 'Thanks for your note! What time works for you today?',
    prepareDraft: async () => ({ gate: gate(), target: { dealerId: 'd', leadId: 'l', contactId: 'c', numberId: 'n' }, chain: { canSendDryRun: async () => OK } }),
    insertDraft: async ({ item: it }) => { log.drafts.push(it.id); return `draft-${it.id}`; },
    linkDraft: async (_i, d2) => { log.links.push(d2); },
    saveReady: async (_id, narrative) => { log.saved = { narrative }; },
    deliver: async () => { log.delivered++; },
    markDelivered: async () => { log.marked++; },
    markFailed: async (_id, e) => { log.failed.push(e); },
    now: () => NOW,
    ...over,
  };
  return { d, log };
}

test('happy path: grounded narration kept, drafts only for draftable kinds, delivered', async () => {
  const { d, log } = deps();
  const s = await processBriefings(d);
  assert.deepEqual(s, { claimed: 1, delivered: 1, failed: 0, drafts: 1, llmFallbacks: 0 });
  assert.deepEqual(log.drafts, ['i1'], 'test_drive_today is not draftable');
  assert.equal(log.marked, 1);
});

test('ungrounded LLM numbers fall back to the deterministic narrative', async () => {
  const { d, log } = deps({ narrate: async () => ({ narrative: 'Good morning! You have 12 hot leads and 9 test drives!' }) });
  const s = await processBriefings(d);
  assert.equal(s.llmFallbacks, 1);
  assert.equal(log.saved!.narrative, fallbackNarrative(FACTS, 2));
});

test('LLM failure or timeout never blocks delivery', async () => {
  const { d } = deps({ narrate: async () => { throw new Error('gateway 500'); } });
  const s = await processBriefings(d);
  assert.deepEqual([s.delivered, s.llmFallbacks], [1, 1]);
  const slow = deps({ narrate: () => new Promise(() => {}) });
  const s2 = await processBriefings(slow.d, { ...DEFAULT_BRIEFING_CONFIG, narrationTimeoutMs: 20 });
  assert.equal(s2.delivered, 1);
});

test('a gate veto on a suggested draft means no draft is created (rep still sees the item)', async () => {
  const { d, log } = deps({ draftReply: async () => 'It is only $9,999 today, guaranteed approval!' });
  const s = await processBriefings(d);
  assert.equal(s.drafts, 0);
  assert.deepEqual(log.drafts, []);
  assert.equal(s.delivered, 1);
});

test('unreachable (DNC / no channel) leads get no draft; failures are recorded, final only at max attempts', async () => {
  const none = deps({ prepareDraft: async () => null });
  assert.equal((await processBriefings(none.d)).drafts, 0);
  const boom = deps({ build: async () => { throw new Error('rpc failed'); } });
  const s = await processBriefings(boom.d);
  assert.deepEqual([s.failed, boom.log.failed.length], [1, 1]);
});

test('grounding helper and fallback text', () => {
  assert.ok(isGrounded('3 replies waiting', ['3 replies']));
  assert.ok(!isGrounded('5 replies waiting', ['3 replies']));
  assert.match(fallbackNarrative(FACTS, 2), /3 replies waiting, 1 test drive today and 3 hot leads gone quiet/);
  assert.match(fallbackNarrative(FACTS, 2), /Showing the top 2/);
  assert.match(fallbackNarrative({ total_candidates: 0, by_kind: {}, size: 5 }, 0), /Nothing urgent/);
  const v = validateNarration({ narrative: 'Good morning. You have 3 things.', itemTexts: { 1: 'Replied 2h ago, wants $5,000 off' } }, { localDate: '2026-11-26', facts: FACTS, items: [{ rank: 1, kind: 'waiting_reply', reason: 'Replied 2h ago and is still waiting' }] });
  assert.deepEqual(v.itemTexts, {}, 'item rewrite with a $ figure is rejected');
});
