/**
 * Pure mapping: SQL get_gate_context() jsonb -> before-send GateInput. One round trip feeds the agent runner,
 * the morning briefing's suggested drafts and the outbound sweeper, so all three run the chain on identical facts.
 */
import { emptyEvidence, type Actor, type Channel, type ComplianceDecision, type GateInput, type Purpose, type SendKind, type TurnEvidence } from './before-send.ts';

export interface GateContextRow {
  dealer_name: string;
  contact: { id: string; dnc_open: boolean };
  lead: { id: string | null; stage: string | null; force_human: boolean; bot_silenced_until: string | null; context_version: number | null; ai_replies_since_inbound: number } | null;
  latest_inbound: { id: string; body: string; at: string; channel: Channel } | null;
  thread: { prior_ai_messages: number; prior_outbound_on_channel: number };
  budget: { cap_cents: number | null; spent_cents: number; hard_stop: boolean } | null;
  settings: {
    ai_disclosure_text: string; stop_footer_text: string; rep_hold_minutes: number; followup_hold_minutes: number;
    auto_send_enabled: boolean; auto_send_kinds: SendKind[] | null; ai_max_unanswered_replies: number; followup_handoff_hours: number;
  };
}

export interface GateRequest {
  actor: Actor; channel: Channel; purpose: Purpose; kind: SendKind; body: string; now: Date;
  evidence?: TurnEvidence; estimateCents?: number; holdElapsed?: boolean;
  /** Proactive sends (follow-ups) pass null so the opt-out gate does not re-read an old inbound as this turn's text. */
  inboundText?: string | null;
}

export function gateInputFromContext(ctx: GateContextRow, r: GateRequest): GateInput {
  if (!ctx || !ctx.settings || !ctx.contact) throw new Error('gate context missing (unknown dealer/contact or no dealer_settings row)');
  const s = ctx.settings;
  return {
    actor: r.actor, channel: r.channel, purpose: r.purpose, kind: r.kind, body: r.body, now: r.now,
    inboundText: r.inboundText !== undefined ? r.inboundText : (ctx.latest_inbound?.body ?? null),
    contact: { id: ctx.contact.id, dncOpen: !!ctx.contact.dnc_open },
    lead: {
      forceHuman: !!ctx.lead?.force_human,
      botSilencedUntil: ctx.lead?.bot_silenced_until ?? null,
      aiRepliesSinceInbound: Number(ctx.lead?.ai_replies_since_inbound ?? 0),
    },
    budget: {
      capCents: ctx.budget?.cap_cents ?? null, spentCents: Number(ctx.budget?.spent_cents ?? 0),
      estimateCents: r.estimateCents ?? 1, hardStop: !!ctx.budget?.hard_stop,
    },
    settings: {
      dealerName: ctx.dealer_name, aiDisclosureText: s.ai_disclosure_text, stopFooterText: s.stop_footer_text,
      repHoldMinutes: s.rep_hold_minutes, followupHoldMinutes: s.followup_hold_minutes,
      autoSendEnabled: s.auto_send_enabled, autoSendKinds: s.auto_send_kinds ?? [], aiMaxUnansweredReplies: s.ai_max_unanswered_replies,
    },
    thread: { priorAiMessages: Number(ctx.thread?.prior_ai_messages ?? 0), priorOutboundToContactOnChannel: Number(ctx.thread?.prior_outbound_on_channel ?? 0) },
    evidence: r.evidence ?? emptyEvidence(),
    compliance: null as ComplianceDecision | null,
    holdElapsed: r.holdElapsed ?? false,
  };
}
