/**
 * Before-send gate chain. Every outbound message, whether proposed by the model's send_message tool or typed
 * by a rep, passes this ordered chain. A gate is a PURE function of its input (unit-test friendly); the only
 * I/O is the injected `deps` used by the `compliance` gate (SQL can_send) and the final reservation.
 *
 * Pattern credits (ideas only, original code): DeskcommCRM (MIT) fixed-order, versioned chain with
 * "stop first" + per-gate traces and veto reasons that are fed back to the model; AgentSDR (MIT)
 * draft/hold/auto-send verdicts and 48h hand-to-rep; wacrm (MIT) per-conversation AI reply cap.
 * Not legal advice.
 */
import { classifyInbound, blocksAutomation, type OptOutResult } from './opt-out.ts';

export const BEFORE_SEND_CHAIN_VERSION = 1;

// ---------------------------------------------------------------- types
export type Channel = 'sms' | 'whatsapp' | 'email';
export type Purpose = 'transactional' | 'conversational' | 'marketing';
export type SendKind = 'reply' | 'followup' | 'cold' | 'transactional';
export type Actor = 'ai' | 'human' | 'system';

export type GateId =
  | 'opt_out' | 'human_owned' | 'ai_budget' | 'ai_reply_cap' | 'compliance'
  | 'sensitive_data' | 'internal_leak' | 'escalation_topics'
  | 'price_apr_promise' | 'in_stock_claim' | 'appointment_claim'
  | 'disclosure' | 'rep_hold';

/** Fixed on purpose: "opt-out first" is a safety invariant; changing the order must bump the version and the test. */
export const BEFORE_SEND_GATES: readonly GateId[] = [
  'opt_out',            // 1  irrevocable; cheapest; nothing below may override it
  'human_owned',        // 2  a person has taken the conversation (force_human / silenced)
  'ai_budget',          // 3  stop spending before we spend more
  'ai_reply_cap',       // 4  no machine-gun: max AI replies since the customer last wrote
  'compliance',         // 5  SQL can_send(): DNC, consent, quiet hours, caps, throttle, anti-template
  'sensitive_data',     // 6  SSN/card numbers in or asked for
  'internal_leak',      // 7  prompt/tool/id leakage, unfilled placeholders
  'escalation_topics',  // 8  legal threats, human requested, safety/recall => human, not bot
  'price_apr_promise',  // 9  every $ and APR must come from a tool result this turn
  'in_stock_claim',     // 10 availability claims need a check_inventory result this turn
  'appointment_claim',  // 11 "confirmed" needs a booked appointment this turn
  'disclosure',         // 12 AI disclosure + STOP footer (mutates the body; last content gate so it can't hide a claim)
  'rep_hold',           // 13 hold for a rep (15 min) or require approval; passes once the hold elapsed
] as const;

export interface VehicleEvidence { vin: string; status: 'available' | 'pending' | 'sold' | 'hold' | 'in_transit'; priceCents?: number | null; msrpCents?: number | null; incentiveCents?: number[]; year?: number | null; make?: string | null; model?: string | null }
export interface QuoteEvidence { monthlyCents?: number; aprPercent?: number; termMonths?: number; downCents?: number; amountFinancedCents?: number }
export interface AppointmentEvidence { startsAt: string; vin?: string | null; status: 'requested' | 'confirmed' }
/** Everything tools returned during THIS turn. Gates trust only this, never the model's own words. */
/** A retrieved knowledge chunk the draft may cite; persisted with record_draft_citations(). */
export interface KnowledgeEvidence { sourceKind: 'kb' | 'vehicle'; chunkId: string; documentId: string | null; vehicleId: string | null; documentVersion: number | null; title: string; score: number }
export interface TurnEvidence { vehicles: VehicleEvidence[]; quotes: QuoteEvidence[]; appointments: AppointmentEvidence[]; knowledge?: KnowledgeEvidence[] }
export const emptyEvidence = (): TurnEvidence => ({ vehicles: [], quotes: [], appointments: [] });

export interface ComplianceDecision { verdict: 'allow' | 'delay' | 'veto'; code: string; reason: string; not_before: string | null; reservation_id: string | null; details?: Record<string, unknown> }

export interface GateInput {
  actor: Actor;
  channel: Channel;
  purpose: Purpose;
  kind: SendKind;
  body: string;
  now: Date;
  inboundText: string | null;               // the customer's latest message this turn (null for proactive sends)
  contact: { id: string; dncOpen: boolean };
  lead: { forceHuman: boolean; botSilencedUntil: string | null; aiRepliesSinceInbound: number };
  budget: { capCents: number | null; spentCents: number; estimateCents: number; hardStop: boolean };
  settings: {
    dealerName: string; aiDisclosureText: string; stopFooterText: string;
    repHoldMinutes: number; followupHoldMinutes: number; autoSendEnabled: boolean; autoSendKinds: SendKind[];
    aiMaxUnansweredReplies: number;
  };
  thread: { priorAiMessages: number; priorOutboundToContactOnChannel: number };
  evidence: TurnEvidence;
  compliance: ComplianceDecision | null;    // filled by the compliance gate's prepare() step
  holdElapsed: boolean;                     // true when the sweeper re-runs the chain after the hold
}

export type GateResult =
  | { verdict: 'allow'; patch?: { body: string }; detail?: Record<string, unknown> }
  | { verdict: 'veto'; code: string; reason: string; action: 'retry' | 'handoff' | 'drop'; detail?: Record<string, unknown> }
  | { verdict: 'delay'; code: string; reason: string; notBefore: string; detail?: Record<string, unknown> }
  | { verdict: 'hold'; code: string; reason: string; holdUntil: string | null; detail?: Record<string, unknown> };

export interface Gate { id: GateId; prepare?: (i: GateInput, deps: ChainDeps) => Promise<GateInput>; run: (i: GateInput) => GateResult }
export interface ChainDeps {
  /** Dry-run SQL can_send (commit=false). Must pass the FINAL candidate body. */
  canSendDryRun: (i: GateInput) => Promise<ComplianceDecision>;
}
export interface Trace { gate: GateId; verdict: GateResult['verdict']; code: string; detail: Record<string, unknown> }
export interface ChainOutcome { result: GateResult; body: string; traces: Trace[]; chainVersion: number }

const ALLOW: GateResult = { verdict: 'allow' };
const veto = (code: string, reason: string, action: 'retry' | 'handoff' | 'drop' = 'retry', detail?: Record<string, unknown>): GateResult => ({ verdict: 'veto', code, reason, action, detail });

// ---------------------------------------------------------------- shared text helpers (exported for tests)
export function moneyAmountsCents(text: string): number[] {
  const out: number[] = [];
  const re = /\$\s?(\d[\d,]*(?:\.\d{1,2})?)(\s?[kK]\b)?|\b(\d[\d,]*(?:\.\d{1,2})?)\s?(?:dollars|bucks)\b/g;
  for (const m of text.matchAll(re)) {
    const raw = (m[1] ?? m[3]).replace(/,/g, '');
    let cents = Math.round(parseFloat(raw) * 100);
    if (m[2]) cents *= 1000;
    if (Number.isFinite(cents)) out.push(cents);
  }
  return out;
}
export function financialPercents(text: string): number[] {
  const out: number[] = [];
  for (const m of text.matchAll(/(\d{1,2}(?:\.\d{1,3})?)\s?%/g)) {
    const at = m.index ?? 0;
    // look only inside the same clause (split on . ; ! ? newline) and within 30 chars either side
    const before = text.slice(Math.max(0, at - 30), at).split(/[.;!?\n]/).pop() ?? '';
    const after = text.slice(at + m[0].length, at + m[0].length + 30).split(/[.;!?\n]/)[0] ?? '';
    if (/\b(apr|rate|interest|financ|lease|money factor|apy)\b/i.test(`${before} ${after}`)) out.push(parseFloat(m[1]));
  }
  return out;
}
export function allowedMoneyCents(e: TurnEvidence): Set<number> {
  const s = new Set<number>();
  for (const v of e.vehicles) {
    for (const x of [v.priceCents, v.msrpCents, ...(v.incentiveCents ?? [])]) if (typeof x === 'number') s.add(x);
  }
  for (const q of e.quotes) for (const x of [q.monthlyCents, q.downCents, q.amountFinancedCents]) if (typeof x === 'number') s.add(x);
  return s;
}
export const VIN_RE = /\b[A-HJ-NPR-Z0-9]{17}\b/gi;
function luhn(digits: string): boolean {
  let sum = 0; let alt = false;
  for (let i = digits.length - 1; i >= 0; i--) { let n = digits.charCodeAt(i) - 48; if (alt) { n *= 2; if (n > 9) n -= 9; } sum += n; alt = !alt; }
  return sum % 10 === 0;
}

// ---------------------------------------------------------------- gates
export const optOutGate: Gate = {
  id: 'opt_out',
  run(i) {
    if (i.contact.dncOpen) return veto('dnc_active', 'The contact opted out. Do not send anything.', 'drop');
    if (i.actor === 'ai' && i.inboundText) {
      const r: OptOutResult = classifyInbound(i.inboundText);
      if (blocksAutomation(r)) {
        return veto(r.level === 'stop' ? 'inbound_stop' : 'inbound_probable_stop',
          'The latest customer message looks like an opt-out. Stop and hand off; a person confirms.', 'handoff',
          { matched_reason: r.reason, confidence: r.confidence, legal_threat: r.legalThreat });
      }
    }
    return ALLOW;
  },
};

export const humanOwnedGate: Gate = {
  id: 'human_owned',
  run(i) {
    if (i.actor !== 'ai') return ALLOW;
    const silenced = i.lead.botSilencedUntil !== null && new Date(i.lead.botSilencedUntil) > i.now;
    if (i.lead.forceHuman || silenced) return veto('human_owned', 'A team member owns this conversation; do not message.', 'drop');
    return ALLOW;
  },
};

export const aiBudgetGate: Gate = {
  id: 'ai_budget',
  run(i) {
    if (i.actor !== 'ai' || i.budget.capCents === null || !i.budget.hardStop) return ALLOW;
    if (i.budget.spentCents + i.budget.estimateCents > i.budget.capCents) {
      return veto('ai_budget_exceeded', 'The dealer AI budget for this month is used up.', 'handoff');
    }
    return ALLOW;
  },
};

export const aiReplyCapGate: Gate = {
  id: 'ai_reply_cap',
  run(i) {
    if (i.actor !== 'ai' || i.kind !== 'reply') return ALLOW;
    if (i.lead.aiRepliesSinceInbound >= i.settings.aiMaxUnansweredReplies) {
      return veto('ai_reply_cap', `You already sent ${i.lead.aiRepliesSinceInbound} messages since the customer last wrote. Wait for them or schedule a follow-up.`, 'drop');
    }
    return ALLOW;
  },
};

export const complianceGate: Gate = {
  id: 'compliance',
  async prepare(i, deps) { return { ...i, compliance: await deps.canSendDryRun(i) }; },
  run(i) {
    const c = i.compliance;
    if (!c) return veto('compliance_unavailable', 'Compliance check did not run; refusing to send.', 'drop');
    if (c.verdict === 'allow') return { verdict: 'allow', detail: { code: c.code } };
    if (c.verdict === 'delay') return { verdict: 'delay', code: c.code, reason: c.reason, notBefore: c.not_before ?? new Date(i.now.getTime() + 60_000).toISOString() };
    const retryable = c.code === 'template_repetition';
    return veto(c.code, c.reason, retryable ? 'retry' : 'drop', c.details);
  },
};

export const sensitiveDataGate: Gate = {
  id: 'sensitive_data',
  run(i) {
    const t = i.body;
    if (/\b\d{3}-?\d{2}-?\d{4}\b/.test(t)) return veto('sensitive_data', 'The message contains something shaped like an SSN. Never send it.', 'retry');
    for (const m of t.matchAll(/\b(?:\d[ -]?){13,19}\b/g)) {
      const d = m[0].replace(/[ -]/g, '');
      if (d.length >= 13 && d.length <= 19 && luhn(d)) return veto('sensitive_data', 'The message contains a payment-card number. Never send it.', 'retry');
    }
    if (/\b(?:social security|ssn|card number|cvv|cvc|driver'?s? licen[cs]e number|bank account number|routing number)\b/i.test(t) && /\b(?:send|text|reply|give|share|provide|what'?s|enter)\b/i.test(t)) {
      return veto('sensitive_data_request', 'Do not ask for sensitive data in chat. Offer the secure pre-qualification link (start_prequal tool) instead.', 'retry');
    }
    return ALLOW;
  },
};

export const internalLeakGate: Gate = {
  id: 'internal_leak',
  run(i) {
    const t = i.body;
    const leak =
      /\b(?:system prompt|tool call|function call|as an ai (?:language )?model|check_inventory|send_message|update_lead_state|schedule_followup|request_human_handoff|before_send|dealer_id|lead_id|agent_runs?)\b/i.test(t)
      || /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i.test(t)
      || /\{\{|\}\}|\[\[|\]\]|<\/?[a-z_]+>|\b(?:undefined|null|NaN)\b|\[(?:NAME|FIRST_NAME|DEALER|VEHICLE)\]/.test(t);
    return leak ? veto('internal_leak', 'The draft leaks internal text or has an unfilled placeholder. Rewrite it in plain customer language.', 'retry') : ALLOW;
  },
};

const TOPICS: { code: string; re: RegExp; reason: string }[] = [
  { code: 'sensitive_shared', re: /\b\d{3}-\d{2}-\d{4}\b|\b(?:ssn|social(?:\s+security)?)\b.{0,20}\b\d{9}\b/i, reason: 'The customer typed what looks like an SSN. Do not engage with it in chat; a rep sends the secure link and the message must be redacted.' },
  { code: 'legal_threat', re: /\b(?:lawyer|attorney|sue|suing|lawsuit|lemon law|tcpa|fcc|attorney general|bbb|cease and desist|class action|report you)\b/i, reason: 'Legal or regulatory language: a manager must respond.' },
  { code: 'negotiation', re: /\b(?:lower|drop|reduce|knock|take)\b.{0,20}\b(?:price|payment|msrp)\b|\b(?:best|lowest|out[- ]the[- ]door|otd|final)\s+(?:price|offer|deal|number)\b|\bnegotiat\w*|\bdiscount\b|\bwill you (?:take|accept)\b|\bhow low\b/i, reason: 'Price negotiation: a person must handle it; the assistant never quotes discounts.' },
  { code: 'human_requested', re: /\b(?:talk|speak|connect me|transfer me|get)\b.{0,25}\b(?:manager|human|real person|a person|someone|salesperson|supervisor|representative)\b/i, reason: 'The customer asked for a person.' },
  { code: 'safety_or_recall', re: /\b(?:recall|airbag|brake failure|accident|injur(?:y|ed)|unsafe|fire|stalled on the highway)\b/i, reason: 'Safety or recall topic: a person must handle it.' },
  { code: 'credit_dispute', re: /\b(?:repossess|bankruptcy|foreclos|identity theft|fraud|dispute (?:the )?charge|chargeback|discriminat)\w*/i, reason: 'Credit, fraud or discrimination topic: a person must handle it.' },
];
export const escalationTopicsGate: Gate = {
  id: 'escalation_topics',
  run(i) {
    if (i.actor !== 'ai' || !i.inboundText) return ALLOW;
    for (const t of TOPICS) if (t.re.test(i.inboundText)) return veto(t.code, t.reason, 'handoff');
    return ALLOW;
  },
};

const FINANCING_GUARANTEE = /\b(?:guaranteed?\s+(?:approval|financing|credit)|everyone(?:'s| is)?\s+approved|you(?:'re| are)\s+(?:pre-?)?approved|no\s+credit\s+check|lowest\s+price\s+(?:guaranteed|in\s+town)|we(?:'ll| will)\s+beat\s+any\s+(?:price|deal|offer)|price\s+match(?:ing)?\s+guarantee)\b/i;
export const priceAprPromiseGate: Gate = {
  id: 'price_apr_promise',
  run(i) {
    const t = i.body;
    if (FINANCING_GUARANTEE.test(t)) {
      return veto('financing_guarantee', 'Never guarantee approval, "no credit check", or beat-any-price. Offer to start a pre-qualification or connect a finance manager.', 'retry');
    }
    const allowed = allowedMoneyCents(i.evidence);
    const stray = moneyAmountsCents(t).filter((c) => !allowed.has(c));
    if (stray.length) {
      return veto('unverified_price',
        `The draft states ${stray.length} dollar amount(s) that no tool returned this turn. Call check_inventory (or a quote tool) first and only quote its numbers, or leave prices out and offer a call.`,
        'retry', { stray_cents: stray });
    }
    const aprs = new Set(i.evidence.quotes.map((q) => q.aprPercent).filter((x): x is number => typeof x === 'number'));
    const strayPct = financialPercents(t).filter((p) => ![...aprs].some((a) => Math.abs(a - p) < 0.001));
    if (strayPct.length) {
      return veto('unverified_apr', 'APR/rate figures must come from a financing quote returned this turn. Do not state rates; offer a pre-qualification link instead.', 'retry', { stray_percent: strayPct });
    }
    return ALLOW;
  },
};

const POSITIVE_STOCK = /\b(?:in stock|on (?:the|our) lot|still (?:have|got|here|available)|we (?:have|got) (?:it|one|that|the|a|an)\b|just (?:came in|arrived|got)|(?:it|that one|the \w+) (?:is|'s) (?:still )?(?:here|available|ready)|ready (?:for|to) (?:a )?(?:test )?drive)\b/i;
const AVAILABLE_WORD = /\bavailable\b/i;
const NON_VEHICLE_AVAILABLE = /\b(?:times?|slots?|appointments?|openings?|someone|reps?|staff|team|we(?:'re| are)|i(?:'m| am)|managers?)\b.{0,18}\bavailable\b|\bavailable\b.{0,14}\b(?:times?|slots?|appointments?|tomorrow|today|saturday|sunday|monday|tuesday|wednesday|thursday|friday)\b/i;
const NEGATIVE_STOCK = /\b(?:sold|no longer available|already (?:been )?sold|just sold|pending sale|not available)\b/i;
function mentions(text: string, v: VehicleEvidence): boolean {
  const t = text.toLowerCase();
  if (t.includes(v.vin.toLowerCase())) return true;
  return !!(v.make && v.model && t.includes(`${v.make} ${v.model}`.toLowerCase())) || !!(v.model && v.model.length > 3 && t.includes(v.model.toLowerCase()));
}
export const inStockClaimGate: Gate = {
  id: 'in_stock_claim',
  run(i) {
    const t = i.body;
    const vins = [...t.matchAll(VIN_RE)].map((m) => m[0].toUpperCase());
    const known = new Map(i.evidence.vehicles.map((v) => [v.vin.toUpperCase(), v]));
    for (const vin of vins) if (!known.has(vin)) return veto('unverified_vin', `VIN ${vin} was not returned by check_inventory this turn. Look it up first.`, 'retry');
    const positive = POSITIVE_STOCK.test(t) || (AVAILABLE_WORD.test(t) && !NON_VEHICLE_AVAILABLE.test(t));
    const negative = NEGATIVE_STOCK.test(t);
    if (!positive && !negative) return ALLOW;
    if (i.evidence.vehicles.length === 0) {
      return veto('unverified_availability', 'The draft makes an availability claim but check_inventory was not called this turn. Call it, then state only what it returned.', 'retry');
    }
    const mentioned = i.evidence.vehicles.filter((v) => mentions(t, v));
    const subject = mentioned.length ? mentioned : i.evidence.vehicles;
    if (positive && subject.some((v) => v.status !== 'available')) {
      return veto('availability_contradiction', 'check_inventory says a vehicle you mention is not available. Do not say it is in stock; offer alternatives.', 'retry');
    }
    if (negative && !positive && subject.every((v) => v.status === 'available')) {
      return veto('availability_contradiction', 'check_inventory says the vehicle is available; do not say it is sold.', 'retry');
    }
    return ALLOW;
  },
};

export const appointmentClaimGate: Gate = {
  id: 'appointment_claim',
  run(i) {
    const t = i.body;
    const claim = /\b(?:confirmed|booked|you(?:'re| are) (?:all )?set|locked in|reserved|see you (?:on|at|tomorrow|today))\b/i.test(t);
    const timeish = /\b\d{1,2}(?::\d{2})?\s?(?:am|pm)\b|\b(?:mon|tues|wednes|thurs|fri|satur|sun)day\b|\btomorrow\b|\btoday\b|\btonight\b/i.test(t);
    if (!(claim && timeish)) return ALLOW;
    if (i.evidence.appointments.length === 0) {
      return veto('unverified_appointment', 'You wrote that a time is confirmed but book_test_drive was not called this turn. Book it first or say you will check availability.', 'retry');
    }
    if (/\bconfirmed\b/i.test(t) && i.evidence.appointments.every((a) => a.status !== 'confirmed')) {
      return veto('appointment_not_confirmed', 'The slot is only requested, not confirmed. Say a team member will confirm it.', 'retry');
    }
    return ALLOW;
  },
};

export const disclosureGate: Gate = {
  id: 'disclosure',
  run(i) {
    if (i.actor === 'human') return ALLOW;
    let body = i.body;
    const parts: string[] = [];
    if (i.actor === 'ai' && i.thread.priorAiMessages === 0 && i.settings.aiDisclosureText) {
      const d = i.settings.aiDisclosureText.replace('{dealer}', i.settings.dealerName);
      if (!/\b(?:virtual assistant|ai assistant|automated assistant|digital assistant)\b/i.test(body)) parts.push(d);
    }
    const needsStop = i.channel !== 'email' && (i.thread.priorOutboundToContactOnChannel === 0 || i.purpose === 'marketing' || i.kind === 'cold');
    if (needsStop && !/\bstop\b/i.test(body) && i.settings.stopFooterText) parts.push(i.settings.stopFooterText);
    if (parts.length === 0) return ALLOW;
    body = `${body.trimEnd()}\n\n${parts.join(' ')}`;
    return { verdict: 'allow', patch: { body }, detail: { appended: parts.length } };
  },
};

export const repHoldGate: Gate = {
  id: 'rep_hold',
  run(i) {
    if (i.actor !== 'ai') return ALLOW;
    if (i.holdElapsed) return ALLOW;
    const auto = i.settings.autoSendEnabled && i.settings.autoSendKinds.includes(i.kind) && i.kind !== 'cold';
    if (!auto) return { verdict: 'hold', code: 'needs_approval', reason: 'Auto-send is off for this kind; a rep must approve.', holdUntil: null };
    const minutes = i.kind === 'reply' ? i.settings.repHoldMinutes : i.settings.followupHoldMinutes;
    if (minutes <= 0) return ALLOW;
    return { verdict: 'hold', code: 'rep_hold', reason: `Held ${minutes} min so a rep can step in.`, holdUntil: new Date(i.now.getTime() + minutes * 60_000).toISOString() };
  },
};

export const DEFAULT_GATES: readonly Gate[] = [
  optOutGate, humanOwnedGate, aiBudgetGate, aiReplyCapGate, complianceGate,
  sensitiveDataGate, internalLeakGate, escalationTopicsGate,
  priceAprPromiseGate, inStockClaimGate, appointmentClaimGate,
  disclosureGate, repHoldGate,
];

// ---------------------------------------------------------------- runner
/** Runs gates in order, stops at the first non-allow. Applies body patches as it goes. */
export async function runChain(input: GateInput, deps: ChainDeps, gates: readonly Gate[] = DEFAULT_GATES): Promise<ChainOutcome> {
  let cur = input;
  const traces: Trace[] = [];
  for (const g of gates) {
    if (g.prepare) cur = await g.prepare(cur, deps);
    const r = g.run(cur);
    traces.push({ gate: g.id, verdict: r.verdict, code: 'code' in r ? r.code : (r.detail?.code as string | undefined) ?? 'ok', detail: { ...(r.detail ?? {}) } });
    if (r.verdict === 'allow') {
      if (r.patch) cur = { ...cur, body: r.patch.body };
      continue;
    }
    return { result: r, body: cur.body, traces, chainVersion: BEFORE_SEND_CHAIN_VERSION };
  }
  return { result: ALLOW, body: cur.body, traces, chainVersion: BEFORE_SEND_CHAIN_VERSION };
}

/** The full decision the Edge Function acts on: run the chain, then (only if it passed) reserve the slot under the number lock. */
export interface SendDeps extends ChainDeps {
  /** can_send(commit=true) with the FINAL body; takes pg_advisory_xact_lock(number) inside Postgres. */
  canSendCommit: (i: GateInput) => Promise<ComplianceDecision>;
}
export type SendDecision =
  | { final: 'send'; body: string; reservationId: string; outcome: ChainOutcome }
  | { final: 'hold'; body: string; holdUntil: string | null; code: string; outcome: ChainOutcome }
  | { final: 'delay'; body: string; notBefore: string; code: string; outcome: ChainOutcome }
  | { final: 'veto'; body: string; code: string; reason: string; action: 'retry' | 'handoff' | 'drop'; outcome: ChainOutcome };

export async function decideSend(input: GateInput, deps: SendDeps, gates: readonly Gate[] = DEFAULT_GATES): Promise<SendDecision> {
  const outcome = await runChain(input, deps, gates);
  const r = outcome.result;
  if (r.verdict === 'veto') return { final: 'veto', body: outcome.body, code: r.code, reason: r.reason, action: r.action, outcome };
  if (r.verdict === 'delay') return { final: 'delay', body: outcome.body, notBefore: r.notBefore, code: r.code, outcome };
  if (r.verdict === 'hold') return { final: 'hold', body: outcome.body, holdUntil: r.holdUntil, code: r.code, outcome };
  // Passed every gate. Reserve under the lock; the SQL re-validates everything, so a race loses cleanly.
  const c = await deps.canSendCommit({ ...input, body: outcome.body });
  if (c.verdict === 'allow' && c.reservation_id) return { final: 'send', body: outcome.body, reservationId: c.reservation_id, outcome };
  if (c.verdict === 'delay') return { final: 'delay', body: outcome.body, notBefore: c.not_before ?? new Date(input.now.getTime() + 60_000).toISOString(), code: c.code, outcome };
  return { final: 'veto', body: outcome.body, code: c.code, reason: c.reason, action: c.code === 'template_repetition' ? 'retry' : 'drop', outcome };
}

// ---------------------------------------------------------------- release of held drafts (AgentSDR-style verdict, original code)
export interface ReleaseCandidate {
  status: string; releaseAt: string | null; createdAt: string; kind: SendKind;
  expectedContextVersion: number | null; leadContextVersion: number | null;
  leadForceHuman: boolean; openInboxForLead: boolean; autoSendEnabled: boolean; handoffHours: number;
  /** A rep approved this exact draft (approve_draft): the auto-send, owner and age checks no longer apply; staleness still does. */
  approved?: boolean;
}
export type ReleaseVerdict = { verdict: 'send' } | { verdict: 'wait'; reason: string } | { verdict: 'hand_to_rep'; reason: 'auto_send_off' | 'lead_needs_person' | 'not_sent_in_window' | 'stale_context' };
export function releaseVerdict(c: ReleaseCandidate, now: Date): ReleaseVerdict {
  if (!c.approved && (c.leadForceHuman || c.openInboxForLead)) return { verdict: 'hand_to_rep', reason: 'lead_needs_person' };
  if (c.expectedContextVersion !== null && c.leadContextVersion !== null && c.expectedContextVersion !== c.leadContextVersion) {
    return { verdict: 'hand_to_rep', reason: 'stale_context' };
  }
  if (!c.approved && !c.autoSendEnabled) return { verdict: 'hand_to_rep', reason: 'auto_send_off' };
  if (!c.approved && now.getTime() - new Date(c.createdAt).getTime() > c.handoffHours * 3_600_000) return { verdict: 'hand_to_rep', reason: 'not_sent_in_window' };
  if (c.releaseAt && new Date(c.releaseAt) > now) return { verdict: 'wait', reason: 'hold not elapsed' };
  return { verdict: 'send' };
}

/** Typing-delay before the first bubble so replies don't land instantly (DeskcommCRM-inspired constants, original code). */
export function humanDelayMs(chars: number, alreadySpentMs = 0, opts = { notice: 900, perChar: 22, min: 1200, max: 7500 }): number {
  const target = Math.min(opts.max, Math.max(opts.min, opts.notice + opts.perChar * chars));
  return Math.max(0, target - alreadySpentMs);
}
