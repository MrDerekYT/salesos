/**
 * Outbound sweeper (pure core). pg_cron -> kick_outbound_sweeper() -> this Edge Function, every minute when work is due.
 *
 *  A. Held/delayed drafts whose release_at passed: claim_due_drafts (SKIP LOCKED) -> releaseVerdict -> re-run the FULL
 *     before-send chain with holdElapsed=true -> can_send(commit) under the number lock -> provider -> finalize_draft_send.
 *  B. Follow-up plans that are due: claim_due_followups (SKIP LOCKED, one per contact) -> compose -> get_gate_context ->
 *     decideSend -> record_followup_outcome. Quiet hours / caps POSTPONE (never drop); content vetoes RETRY (capped);
 *     no consent / DNC / a person owns the lead STOP. Anything unexpected is a retry, so a crash never loses a plan.
 *
 * Every customer-facing send goes through the same chain + SQL can_send() as the live agent. Pattern credit: AgentSDR
 * (hold/release verdict), DeskcommCRM (gate chain), wacrm (re-engagement triggers); MIT. Code is original.
 */
import { decideSend, releaseVerdict, type Channel, type ComplianceDecision, type GateInput, type Purpose, type ReleaseCandidate, type SendDeps, type SendKind, type TurnEvidence, type VehicleEvidence } from '../_shared/before-send.ts';
import { gateInputFromContext, type GateContextRow } from '../_shared/gate-context.ts';

export interface DueDraft {
  id: string; dealer_id: string; lead_id: string | null; contact_id: string; channel: Channel; number_id: string; actor: 'ai' | 'human' | 'system';
  purpose: Purpose; kind: SendKind; body_ai: string; body_edited: string | null; evidence: TurnEvidence | null; status: string;
  release_at: string | null; created_at: string; expected_context_version: number | null;
}
export type FollowupTrigger = 'stalled' | 'promised' | 'price_drop' | 'test_drive_noshow' | 'service_due' | 'lease_end';
export interface DuePlan {
  id: string; dealer_id: string; lead_id: string | null; contact_id: string; trigger_kind: FollowupTrigger; purpose: Purpose;
  channel: Channel | null; vehicle_id: string | null; attempts: number; context: Record<string, unknown>;
}
export interface Route { channel: Channel; numberId: string }
export interface SendTarget { dealerId: string; contactId: string; leadId: string | null; numberId: string; idempotencyKey?: string | null }
/** Everything the dispatcher needs; idempotencyKey is draft:<id> for drafts and plan:<id>:<attempt> for follow-ups. */
export interface ProviderSendArgs {
  channel: Channel; numberId: string; contactId: string; body: string;
  dealerId: string; draftId: string | null; purpose: Purpose; kind: SendKind; idempotencyKey: string;
  template?: { name: string; language: string; params: string[] } | null;
}
export interface TemplateChoice { name: string; language: string; params: string[]; body: string }
export type ProviderResult = { ok: true; providerMessageId: string } | { ok: false; error: string; retryable: boolean };
export type FollowupOutcome = 'sent' | 'drafted' | 'delayed' | 'retry' | 'stop';

export interface SweeperDeps {
  now(): Date;
  claimDrafts(limit: number): Promise<DueDraft[]>;
  releaseFacts(d: DueDraft): Promise<Omit<ReleaseCandidate, 'status' | 'releaseAt' | 'createdAt' | 'kind' | 'expectedContextVersion'>>;
  setDraftStatus(id: string, status: 'held' | 'delayed' | 'vetoed' | 'handed_to_rep' | 'awaiting_review' | 'sending', patch?: { releaseAt?: string | null; vetoCode?: string; reservationId?: string; body?: string }): Promise<void>;
  gateContext(dealerId: string, contactId: string, leadId: string | null, channel: Channel, now: Date): Promise<GateContextRow>;
  canSend(t: SendTarget, i: GateInput, commit: boolean): Promise<ComplianceDecision>;
  providerSend(a: ProviderSendArgs): Promise<ProviderResult>;
  /** WhatsApp outside the 24 h window: an approved template rendered with the follow-up's facts ('not_needed' inside it). */
  templateFor?(a: { plan: DuePlan; route: Route; facts: { firstName: string | null; vehicle: VehicleEvidence | null; dealerName: string } }): Promise<TemplateChoice | 'not_needed' | null>;
  finalize(draftId: string, r: ProviderResult, body: string): Promise<void>;

  claimFollowups(limit: number): Promise<DuePlan[]>;
  pickRoute(dealerId: string, contactId: string, preferred: Channel | null): Promise<Route | null>;
  followupFacts(p: DuePlan): Promise<{ firstName: string | null; vehicle: VehicleEvidence | null }>;
  /** Optional LLM wording; must return null on any doubt so the deterministic template is used. */
  composeWithLlm?(p: DuePlan, facts: { firstName: string | null; vehicle: VehicleEvidence | null; dealerName: string }): Promise<string | null>;
  insertDraft(a: { plan: DuePlan; route: Route; body: string; status: 'sending' | 'held' | 'awaiting_review'; releaseAt: string | null; reservationId: string | null; evidence: TurnEvidence; chainVersion: number }): Promise<string>;
  recordOutcome(planId: string, outcome: FollowupOutcome, code: string | null, notBefore: string | null, draftId: string | null): Promise<string>;
  log?(event: string, data: Record<string, unknown>): void;
}
export interface SweepSummary {
  drafts: { claimed: number; sent: number; held: number; delayed: number; vetoed: number; handed: number; failed: number };
  followups: { claimed: number; sent: number; drafted: number; postponed: number; retried: number; stopped: number; errors: number };
}

const usd = (cents: number) => `$${Math.round(cents / 100).toLocaleString('en-US')}`;
const vehicleName = (v: VehicleEvidence | null) => (v ? [v.year, v.make, v.model].filter(Boolean).join(' ') : 'the vehicle');
/** Hard vetoes that mean "not ours to send" rather than "try different words". */
export const STOP_CODES: ReadonlySet<string> = new Set(['dnc_active', 'no_consent', 'no_address', 'contact_anonymized', 'cold_requires_marketing', 'human_owned', 'bot_silenced', 'opt_out', 'opt_out_inbound', 'ai_reply_cap', 'email_suppressed']);

/** Deterministic, evidence-only wording (the price/APR and in-stock gates accept it because the numbers come from evidence). */
export function followupTemplate(p: DuePlan, f: { firstName: string | null; vehicle: VehicleEvidence | null; dealerName: string }): string | null {
  const hi = f.firstName ? `Hi ${f.firstName}` : 'Hi';
  switch (p.trigger_kind) {
    case 'stalled': return `${hi}, it's ${f.dealerName}. Just checking in: any questions I can answer about ${f.vehicle ? 'the ' + vehicleName(f.vehicle) : 'your search'}?`;
    case 'promised': {
      const reason = typeof p.context.reason === 'string' ? p.context.reason : 'what we talked about';
      return `${hi}, following up as promised on ${reason.replace(/[.!?]+$/, '')}. I'll have an update for you shortly. Is now still a good time?`;
    }
    case 'price_drop': {
      if (!f.vehicle || f.vehicle.priceCents == null || !['available', 'in_transit'].includes(f.vehicle.status)) return null;
      return `${hi}, good news from ${f.dealerName}: the ${vehicleName(f.vehicle)} you looked at is now ${usd(f.vehicle.priceCents)}. Want me to hold a time for you to see it?`;
    }
    case 'test_drive_noshow': return `${hi}, sorry we missed you for your test drive at ${f.dealerName}. Want to pick another time that works better?`;
    case 'service_due': {
      const name = [p.context.year, p.context.make, p.context.model].filter(Boolean).join(' ') || 'your vehicle';
      return `${hi}, ${f.dealerName} here. Your ${name} is coming due for service. Want me to set up a time?`;
    }
    case 'lease_end': return `${hi}, ${f.dealerName} here. Your lease end is coming up. Happy to walk you through your options whenever it suits you.`;
  }
}

export function outcomeForDecision(final: 'send' | 'hold' | 'delay' | 'veto', code: string, action?: 'retry' | 'handoff' | 'drop'): FollowupOutcome {
  if (final === 'send') return 'sent';
  if (final === 'hold') return 'drafted';
  if (final === 'delay') return 'delayed';
  if (STOP_CODES.has(code) || action === 'handoff' || action === 'drop') return 'stop';
  return 'retry';
}

function sendDepsFor(deps: SweeperDeps, t: SendTarget): SendDeps {
  return { canSendDryRun: (i) => deps.canSend({ ...t, idempotencyKey: null }, i, false), canSendCommit: (i) => deps.canSend(t, i, true) };
}

export async function sweepDrafts(deps: SweeperDeps, sum: SweepSummary['drafts'], limit = 50): Promise<void> {
  const now = deps.now();
  const drafts = await deps.claimDrafts(limit);
  sum.claimed += drafts.length;
  for (const d of drafts) {
    try {
      const facts = await deps.releaseFacts(d);
      const rv = releaseVerdict({ ...facts, status: d.status, releaseAt: d.release_at, createdAt: d.created_at, kind: d.kind, expectedContextVersion: d.expected_context_version }, now);
      if (rv.verdict === 'wait') { await deps.setDraftStatus(d.id, 'held', { releaseAt: d.release_at }); sum.held++; continue; }
      if (rv.verdict === 'hand_to_rep') { await deps.setDraftStatus(d.id, 'handed_to_rep', { vetoCode: rv.reason }); sum.handed++; continue; }
      const key = `draft:${d.id}`;
      const t: SendTarget = { dealerId: d.dealer_id, contactId: d.contact_id, leadId: d.lead_id, numberId: d.number_id, idempotencyKey: key };
      const ctx = await deps.gateContext(d.dealer_id, d.contact_id, d.lead_id, d.channel, now);
      const body = d.body_edited ?? d.body_ai;
      const input = gateInputFromContext(ctx, { actor: d.actor, channel: d.channel, purpose: d.purpose, kind: d.kind, body, now, evidence: d.evidence ?? undefined, holdElapsed: true });
      const dec = await decideSend(input, sendDepsFor(deps, t));
      if (dec.final === 'send') {
        await deps.setDraftStatus(d.id, 'sending', { reservationId: dec.reservationId, body: dec.body });
        const r = await deps.providerSend({ channel: d.channel, numberId: d.number_id, contactId: d.contact_id, body: dec.body, dealerId: d.dealer_id, draftId: d.id,
                                            purpose: d.purpose, kind: d.kind, idempotencyKey: key });
        await deps.finalize(d.id, r, dec.body);
        if (r.ok) sum.sent++; else sum.failed++;
      } else if (dec.final === 'delay') { await deps.setDraftStatus(d.id, 'delayed', { releaseAt: dec.notBefore, vetoCode: dec.code }); sum.delayed++; }
      else if (dec.final === 'hold') { await deps.setDraftStatus(d.id, 'awaiting_review', { vetoCode: dec.code }); sum.held++; }   // holdElapsed + still holding => a person decides
      else { await deps.setDraftStatus(d.id, dec.action === 'handoff' ? 'handed_to_rep' : 'vetoed', { vetoCode: dec.code }); sum.vetoed++; }
    } catch (e) {
      sum.failed++;
      deps.log?.('draft_error', { draft_id: d.id, error: (e as Error).message });
      await deps.setDraftStatus(d.id, 'awaiting_review', { vetoCode: 'sweeper_error' }).catch(() => undefined);
    }
  }
}

export async function sweepFollowups(deps: SweeperDeps, sum: SweepSummary['followups'], limit = 50): Promise<void> {
  const now = deps.now();
  const plans = await deps.claimFollowups(limit);
  sum.claimed += plans.length;
  const tally = (status: string) => {
    if (status === 'sent') sum.sent++; else if (status === 'drafted') sum.drafted++;
    else if (status === 'postponed') sum.postponed++; else if (status === 'cancelled') sum.stopped++; else sum.retried++;
  };
  for (const p of plans) {
    try {
      const route = await deps.pickRoute(p.dealer_id, p.contact_id, p.channel);
      if (!route) { tally(await deps.recordOutcome(p.id, 'stop', 'unreachable', null, null)); continue; }
      const ctx = await deps.gateContext(p.dealer_id, p.contact_id, p.lead_id, route.channel, now);
      const facts = await deps.followupFacts(p);
      const f = { ...facts, dealerName: ctx.dealer_name };
      if (p.trigger_kind === 'price_drop' && (!facts.vehicle || !['available', 'in_transit'].includes(facts.vehicle.status))) {
        tally(await deps.recordOutcome(p.id, 'stop', 'vehicle_unavailable', null, null)); continue;
      }
      const evidence: TurnEvidence = { vehicles: facts.vehicle ? [facts.vehicle] : [], quotes: [], appointments: [] };
      // Try LLM wording first, then the template if the chain asks for different words (content veto) or the LLM declines.
      let template: TemplateChoice | null = null;
      if (route.channel === 'whatsapp' && deps.templateFor) {
        const tc = await deps.templateFor({ plan: p, route, facts: f });
        if (tc === null) { tally(await deps.recordOutcome(p.id, 'stop', 'whatsapp_template_missing', null, null)); continue; }
        if (tc !== 'not_needed') template = tc;
      }
      // Outside the WhatsApp window the ONLY possible text is the approved template, so that rendered text is what the gates check.
      const candidates = template ? [template.body]
        : [await deps.composeWithLlm?.(p, f).catch(() => null), followupTemplate(p, f)].filter((b): b is string => !!b && b.trim().length > 0);
      if (candidates.length === 0) { tally(await deps.recordOutcome(p.id, 'retry', 'compose_failed', null, null)); continue; }
      const key = `plan:${p.id}:${p.attempts}`;
      let done = false;
      for (const [idx, body] of candidates.entries()) {
        const input = gateInputFromContext(ctx, { actor: 'ai', channel: route.channel, purpose: p.purpose, kind: 'followup', body, now, evidence, inboundText: null });
        const t: SendTarget = { dealerId: p.dealer_id, contactId: p.contact_id, leadId: p.lead_id, numberId: route.numberId, idempotencyKey: key };
        const dec = await decideSend({ ...input, purpose: p.purpose }, sendDepsFor(deps, t));
        const outcome = outcomeForDecision(dec.final, dec.final === 'send' ? 'ok' : dec.code, dec.final === 'veto' ? dec.action : undefined);
        if (outcome === 'retry' && idx < candidates.length - 1) continue;            // content veto on LLM text: fall back to the template
        if (dec.final === 'send') {
          const draftId = await deps.insertDraft({ plan: p, route, body: dec.body, status: 'sending', releaseAt: null, reservationId: dec.reservationId, evidence, chainVersion: dec.outcome.chainVersion });
          const r = await deps.providerSend({ channel: route.channel, numberId: route.numberId, contactId: p.contact_id, body: dec.body, dealerId: p.dealer_id, draftId,
                                              purpose: p.purpose, kind: 'followup', idempotencyKey: key, template });
          await deps.finalize(draftId, r, dec.body);
          tally(r.ok ? await deps.recordOutcome(p.id, 'sent', 'ok', null, draftId) : await deps.recordOutcome(p.id, r.retryable ? 'retry' : 'stop', 'provider_error', null, draftId));
        } else if (dec.final === 'hold') {
          const draftId = await deps.insertDraft({ plan: p, route, body: dec.body, status: dec.holdUntil ? 'held' : 'awaiting_review', releaseAt: dec.holdUntil, reservationId: null, evidence, chainVersion: dec.outcome.chainVersion });
          tally(await deps.recordOutcome(p.id, 'drafted', dec.code, null, draftId));
        } else if (dec.final === 'delay') {
          tally(await deps.recordOutcome(p.id, 'delayed', dec.code, dec.notBefore, null));
        } else {
          tally(await deps.recordOutcome(p.id, outcome, dec.code, null, null));
        }
        done = true; break;
      }
      if (!done) tally(await deps.recordOutcome(p.id, 'retry', 'no_candidate', null, null));
    } catch (e) {
      sum.errors++;
      deps.log?.('followup_error', { plan_id: p.id, error: (e as Error).message });
      await deps.recordOutcome(p.id, 'retry', 'sweeper_error', null, null).catch(() => undefined);
    }
  }
}

export async function sweep(deps: SweeperDeps, cfg = { draftLimit: 50, followupLimit: 50 }): Promise<SweepSummary> {
  const sum: SweepSummary = {
    drafts: { claimed: 0, sent: 0, held: 0, delayed: 0, vetoed: 0, handed: 0, failed: 0 },
    followups: { claimed: 0, sent: 0, drafted: 0, postponed: 0, retried: 0, stopped: 0, errors: 0 },
  };
  await sweepDrafts(deps, sum.drafts, cfg.draftLimit);          // already-approved work first
  await sweepFollowups(deps, sum.followups, cfg.followupLimit);
  deps.log?.('sweep', sum as unknown as Record<string, unknown>);
  return sum;
}
