/**
 * Vercel AI SDK tool definitions for the SalesOS dealership agent.
 *
 * Rules enforced here (the "harness", not the prompt):
 *  - Every input schema is Zod `.strict()`: a model can never smuggle dealer_id / lead_id / contact_id or any other
 *    field. Tenancy and identity come ONLY from `AgentToolContext` (built by the runner from the job row).
 *  - Plain model text is never delivered. The only way to reach a customer is `send_message`, which runs the
 *    before-send chain (supabase/functions/_shared/before-send.ts) and usually lands in the rep-hold queue.
 *  - Tools return `{ ok:false, error:{code,message} }` with a TEACHING message instead of throwing, so the model can
 *    correct itself inside the same turn (pattern credit: DeskcommCRM, MIT; code is original).
 *  - Tool results that carry facts (inventory, quotes, appointments) are copied into `ctx.evidence`; the price/APR,
 *    in-stock and appointment gates only trust that evidence.
 */
import { tool } from 'ai';
import { z } from 'zod';
import type { TurnEvidence, VehicleEvidence, SendKind, KnowledgeEvidence } from './before-send.ts';
import { FACT_KEYS, MIN_FACT_CONFIDENCE, validateFact } from './facts.ts';

// ------------------------------------------------------------------ result envelope
export type ToolError = { code: string; message: string; retryable?: boolean };
export type ToolResult<T extends object = Record<string, never>> = ({ ok: true } & T) | { ok: false; error: ToolError };
const fail = (code: string, message: string, retryable = false): { ok: false; error: ToolError } => ({ ok: false, error: { code, message, retryable } });

// ------------------------------------------------------------------ shared field schemas
const vin = z.string().regex(/^[A-HJ-NPR-Z0-9]{17}$/i, 'VIN must be 17 characters (no I, O, Q)').transform((v) => v.toUpperCase());
const isoWithOffset = z.iso.datetime({ offset: true });
const channelEnum = z.enum(['sms', 'whatsapp', 'email']);
export const LEAD_STAGES = ['new', 'contacted', 'qualifying', 'qualified', 'test_drive', 'negotiating', 'won', 'lost'] as const;

// ------------------------------------------------------------------ input schemas (exported so tests/OpenAPI can reuse them)
export const sendMessageInput = z.object({
  body: z.string().trim().min(1).max(1000).describe('The exact text to send to the customer. Plain language, no placeholders, no internal terms.'),
  channel: channelEnum.optional().describe('Defaults to the channel the customer last used.'),
  reply_to_message_id: z.uuid().optional().describe('The inbound message you are answering, if any.'),
}).strict();

export const updateLeadStateInput = z.object({
  stage: z.enum(LEAD_STAGES),
  confidence: z.number().min(0).max(1).describe('How sure you are that the customer\'s words justify this stage.'),
  reason: z.string().trim().min(5).max(280),
  evidence_quote: z.string().trim().min(3).max(300).describe('The customer\'s own words that justify the change, verbatim.'),
}).strict();

export const recordCustomerFactInput = z.object({
  key: z.enum(FACT_KEYS).describe('budget_max_cents (whole CENTS: $35,000 = 3500000), trade_in_vin (17-char VIN), preferred_trim, purchase_timeframe (now|within_30_days|within_90_days|later), wants_financing (true|false).'),
  value: z.union([z.string().max(60), z.number(), z.boolean()]),
  confidence: z.number().min(0).max(1).describe('How sure you are the customer stated this. Below 0.5 is refused: ask instead.'),
  evidence_quote: z.string().trim().min(3).max(300).describe('The customer\'s own words, copied exactly from their message. If it is not in the thread the fact is refused.'),
}).strict();

export const scheduleFollowupInput = z.object({
  when: isoWithOffset.describe('When to follow up (ISO-8601 with offset). Between 10 minutes and 30 days from now.'),
  reason: z.string().trim().min(3).max(200),
  promised_text: z.string().trim().max(200).optional().describe('What you told the customer you would do, in their words.'),
}).strict();

export const searchKnowledgeInput = z.object({
  query: z.string().trim().min(3).max(300),
  kinds: z.array(z.enum(['faq', 'financing', 'trade_in', 'policy', 'incentive', 'objection', 'scheduling', 'vehicle_description'])).max(4).optional(),
  top_k: z.number().int().min(1).max(8).default(4),
}).strict();

export const requestHumanHandoffInput = z.object({
  reason: z.enum(['customer_requested', 'legal', 'financing_question', 'negotiation', 'complaint', 'safety', 'opt_out_unclear', 'unsure', 'other']),
  summary: z.string().trim().min(10).max(500).describe('What the rep needs to know in two sentences. No SSN/credit data.'),
  urgency: z.enum(['low', 'normal', 'urgent']).default('normal'),
}).strict();

export const checkInventoryInput = z.object({
  vin: vin.optional(),
  make: z.string().trim().max(40).optional(),
  model: z.string().trim().max(60).optional(),
  year_min: z.number().int().min(1980).max(2100).optional(),
  year_max: z.number().int().min(1980).max(2100).optional(),
  max_price_cents: z.number().int().positive().optional(),
  body_style: z.string().trim().max(40).optional(),
  condition: z.enum(['new', 'used', 'cpo']).optional(),
  limit: z.number().int().min(1).max(5).default(3),
}).strict().refine((v) => v.vin || v.make || v.model || v.body_style || v.max_price_cents || v.year_min || v.year_max || v.condition,
  { message: 'Give at least one filter (vin, make, model, body_style, price, year or condition).' });

export const bookTestDriveInput = z.object({
  vin,
  slot_start: isoWithOffset.describe('Start time, ISO-8601 with the dealership\'s UTC offset.'),
  duration_min: z.number().int().min(15).max(120).default(30),
  notes: z.string().trim().max(200).optional(),
}).strict();

export const requestTradeInAppraisalInput = z.object({
  year: z.number().int().min(1980).max(2100),
  make: z.string().trim().min(1).max(40),
  model: z.string().trim().min(1).max(60),
  trim: z.string().trim().max(60).optional(),
  mileage: z.number().int().min(0).max(1_000_000),
  vin: vin.optional(),
  condition: z.enum(['excellent', 'good', 'fair', 'poor']),
  has_lien: z.boolean().optional(),
}).strict();

export const startPrequalInput = z.object({
  desired_term_months: z.number().int().min(12).max(96).optional(),
  down_payment_cents: z.number().int().min(0).optional(),
  vehicle_vin: vin.optional(),
}).strict();

// ------------------------------------------------------------------ runtime context (trusted; never from the model)
export interface InventoryRow extends VehicleEvidence { trim?: string | null; mileage?: number | null; condition?: string | null; exteriorColor?: string | null }
/** One retrieval hit (see supabase/functions/_shared/rag.ts). `citation` is present when the hit came from match_kb. */
export interface KnowledgeHit { id: string; title: string; kind: string; excerpt: string; score: number; citation?: KnowledgeEvidence }
export interface AgentToolDeps {
  proposeSend(a: { body: string; channel?: 'sms' | 'whatsapp' | 'email'; replyToMessageId?: string; kind: SendKind; evidence: TurnEvidence }):
    Promise<{ final: 'held' | 'sent' | 'delayed' | 'vetoed'; draftId?: string; holdUntil?: string | null; notBefore?: string; code?: string; reason?: string; action?: 'retry' | 'handoff' | 'drop' }>;
  updateLeadState(a: { stage: typeof LEAD_STAGES[number]; confidence: number; reason: string; quote: string }): Promise<'applied' | 'review' | 'noop'>;
  scheduleFollowup(a: { dueAt: Date; reason: string; promisedText?: string }): Promise<{ followupId: string }>;
  recordFact(a: { key: string; value: string | number | boolean; confidence: number; quote: string }): Promise<{ result: 'inserted' | 'superseded' | 'unchanged' | 'kept_existing' | 'stale' | 'rejected'; code?: string; message?: string; factId?: string }>;
  searchKnowledge(a: { query: string; kinds?: string[]; topK: number }): Promise<KnowledgeHit[]>;
  handoff(a: { reason: string; summary: string; urgency: 'low' | 'normal' | 'urgent' }): Promise<{ inboxItemId: string }>;
  searchInventory(a: z.infer<typeof checkInventoryInput>): Promise<InventoryRow[]>;
  bookTestDrive(a: { vin: string; slotStart: Date; durationMin: number; notes?: string }): Promise<
    { status: 'requested' | 'confirmed'; appointmentId: string } | { status: 'unavailable'; reason: string; alternatives: string[] }>;
  requestAppraisal(a: z.infer<typeof requestTradeInAppraisalInput>): Promise<{ appraisalId: string; expectedResponseHours: number }>;
  createPrequalLink(a: { termMonths?: number; downPaymentCents?: number; vin?: string }): Promise<{ url: string; expiresAt: string }>;
  recordToolCall?(a: { tool: string; resultCode: string; durationMs: number; args: unknown }): Promise<void> | void;
}
export interface AgentToolContext {
  /** Trusted identity from the job row; the model has no way to set or change these. */
  dealerId: string; leadId: string; contactId: string; runId: string;
  turnKind: SendKind;
  evidence: TurnEvidence;
  deps: AgentToolDeps;
  now?: () => Date;
  limits?: { maxSendAttempts: number; maxMessagesPerTurn: number };
  state?: { sendAttempts: number; messagesQueued: number; handedOff: boolean };
}

export const AGENT_TOOL_NAMES = [
  'send_message', 'update_lead_state', 'record_customer_fact', 'schedule_followup', 'search_knowledge', 'request_human_handoff',
  'check_inventory', 'book_test_drive', 'request_trade_in_appraisal', 'start_prequal',
] as const;
export type AgentToolName = typeof AGENT_TOOL_NAMES[number];

function mergeVehicles(ev: TurnEvidence, rows: InventoryRow[]): void {
  for (const r of rows) {
    const i = ev.vehicles.findIndex((v) => v.vin.toUpperCase() === r.vin.toUpperCase());
    const clean: VehicleEvidence = { vin: r.vin.toUpperCase(), status: r.status, priceCents: r.priceCents ?? null, msrpCents: r.msrpCents ?? null, incentiveCents: r.incentiveCents ?? [], year: r.year ?? null, make: r.make ?? null, model: r.model ?? null };
    if (i >= 0) ev.vehicles[i] = clean; else ev.vehicles.push(clean);
  }
}

/** Builds the tool set for ONE turn. Pass the result straight to generateText/ToolLoopAgent `tools`. */
export function createAgentTools(ctx: AgentToolContext) {
  const now = ctx.now ?? (() => new Date());
  const limits = ctx.limits ?? { maxSendAttempts: 3, maxMessagesPerTurn: 2 };
  const state = (ctx.state ??= { sendAttempts: 0, messagesQueued: 0, handedOff: false });

  /** Times every call and records it to agent_tool_calls (args are redacted by the dep). Never throws into the model. */
  async function traced<T extends { ok: boolean }>(name: AgentToolName, args: unknown, fn: () => Promise<T>): Promise<T | { ok: false; error: ToolError }> {
    const t0 = Date.now();
    let out: T | { ok: false; error: ToolError };
    try { out = await fn(); } catch (e) {
      out = fail('tool_failed', `The ${name} tool failed (${e instanceof Error ? e.message.slice(0, 120) : 'unknown'}). Do not retry blindly; if this blocks the customer, call request_human_handoff.`);
    }
    try { await ctx.deps.recordToolCall?.({ tool: name, resultCode: out.ok ? 'ok' : (out as { error: ToolError }).error.code, durationMs: Date.now() - t0, args }); } catch { /* telemetry must not break a turn */ }
    return out;
  }

  return {
    send_message: tool({
      description:
        'The ONLY way to message the customer. The text goes through compliance and accuracy checks and is usually held for a rep. ' +
        'If it is refused, read the reason, fix the draft, and try again (max 3 tries). Never repeat a message that was held or sent.',
      inputSchema: sendMessageInput,
      execute: (args) => traced('send_message', args, async () => {
        if (state.handedOff) return fail('handed_off', 'A person has taken over this conversation. Do not send anything.');
        if (state.messagesQueued >= limits.maxMessagesPerTurn) return fail('turn_message_limit', 'You already queued the maximum messages for this turn. Stop here.');
        if (state.sendAttempts >= limits.maxSendAttempts) return fail('too_many_retries', 'Too many refused drafts this turn. Call request_human_handoff with a short summary.');
        state.sendAttempts += 1;
        const r = await ctx.deps.proposeSend({ body: args.body, channel: args.channel, replyToMessageId: args.reply_to_message_id, kind: ctx.turnKind, evidence: ctx.evidence });
        if (r.final === 'vetoed') {
          if (r.action === 'handoff') { state.handedOff = true; return fail(r.code ?? 'vetoed', `${r.reason ?? 'Refused.'} Call request_human_handoff now; do not message the customer.`); }
          if (r.action === 'drop') return fail(r.code ?? 'vetoed', `${r.reason ?? 'Refused.'} Do not send anything else on this thread.`);
          return fail(r.code ?? 'vetoed', r.reason ?? 'Refused. Rewrite the draft.', true);
        }
        state.messagesQueued += 1;
        if (r.final === 'sent') return { ok: true as const, status: 'sent' as const, note: 'Delivered. Do not repeat it.' };
        if (r.final === 'delayed') return { ok: true as const, status: 'delayed' as const, not_before: r.notBefore, note: 'Scheduled for the next allowed time (quiet hours or daily limits). Do not repeat it.' };
        return { ok: true as const, status: 'held' as const, hold_until: r.holdUntil ?? null, note: 'Queued for a rep to approve. Do not repeat it or tell the customer it was sent.' };
      }),
    }),

    update_lead_state: tool({
      description:
        'Record where the deal stands, with the customer\'s own words as evidence. You may only move a lead FORWARD. Moves to won/lost, backward moves or low confidence are sent to a rep to confirm. ' +
        'Do not tell the customer their stage changed.',
      inputSchema: updateLeadStateInput,
      execute: (args) => traced('update_lead_state', { stage: args.stage, confidence: args.confidence }, async () => {
        const result = await ctx.deps.updateLeadState({ stage: args.stage, confidence: args.confidence, reason: args.reason, quote: args.evidence_quote });
        return { ok: true as const, result, note: result === 'review' ? 'A rep will confirm this change.' : result === 'noop' ? 'Already at that stage.' : 'Applied.' };
      }),
    }),

    record_customer_fact: tool({
      description:
        'Save ONE thing the customer told you so the team does not have to ask again: budget, trade-in VIN, preferred trim, purchase timeframe, or whether they want financing. ' +
        'Only record what the customer actually wrote, with their exact words as evidence_quote. A newer statement replaces an older one (the history is kept). ' +
        'Never record credit scores, SSN, income or anything not listed. Do not tell the customer you saved it.',
      inputSchema: recordCustomerFactInput,
      execute: (args) => traced('record_customer_fact', { key: args.key, confidence: args.confidence }, async () => {
        if (args.confidence < MIN_FACT_CONFIDENCE) return fail('low_confidence', 'Only record facts you are at least 50% sure the customer stated. Ask them instead.');
        const v = validateFact(args.key, args.value);
        if (!v.ok) return fail(v.code, v.message);
        const r = await ctx.deps.recordFact({ key: args.key, value: v.value, confidence: args.confidence, quote: args.evidence_quote });
        if (r.result === 'rejected') return fail(r.code ?? 'rejected', r.message ?? 'The fact was refused.');
        const note = r.result === 'kept_existing' ? 'A team member already recorded this; leave it.' : r.result === 'stale' ? 'A newer message already set this.' : r.result === 'unchanged' ? 'Already known.' : 'Saved.';
        return { ok: true as const, result: r.result, note };
      }),
    }),

    schedule_followup: tool({
      description:
        'Promise-keeping: schedule your own follow-up (10 minutes to 30 days out). Use it whenever you tell the customer you will check back. ' +
        'It is NOT a booked appointment. Quiet hours and consent are enforced when it fires.',
      inputSchema: scheduleFollowupInput,
      execute: (args) => traced('schedule_followup', { when: args.when }, async () => {
        const due = new Date(args.when);
        const mins = (due.getTime() - now().getTime()) / 60_000;
        if (!(mins >= 10)) return fail('followup_too_soon', 'Pick a time at least 10 minutes from now.');
        if (mins > 30 * 24 * 60) return fail('followup_too_far', 'Pick a time within 30 days; for later, hand off to a rep.');
        const r = await ctx.deps.scheduleFollowup({ dueAt: due, reason: args.reason, promisedText: args.promised_text });
        return { ok: true as const, followup_id: r.followupId, note: 'Scheduled. You can tell the customer you will follow up, but do not promise an exact minute.' };
      }),
    }),

    search_knowledge: tool({
      description:
        'Search the dealership\'s own FAQs, financing/trade-in policies, incentives and vehicle descriptions. ' +
        'NEVER use it for price or availability: use check_inventory for those. Quote sources faithfully; if nothing relevant comes back, say you will check.',
      inputSchema: searchKnowledgeInput,
      execute: (args) => traced('search_knowledge', { top_k: args.top_k, kinds: args.kinds }, async () => {
        const hits = await ctx.deps.searchKnowledge({ query: args.query, kinds: args.kinds, topK: args.top_k });
        if (hits.length === 0) return fail('no_knowledge', 'Nothing relevant was found. Do not guess; say you will check with the team or hand off.');
        // Every hit the model saw becomes citable evidence; the sweeper/runner persists it with record_draft_citations().
        const known = (ctx.evidence.knowledge ??= []);
        for (const h of hits) if (h.citation && !known.some((k) => k.chunkId === h.citation!.chunkId)) known.push(h.citation);
        return { ok: true as const, results: hits.map((h) => ({ id: h.id, title: h.title, kind: h.kind, excerpt: h.excerpt.slice(0, 600), score: Number(h.score.toFixed(3)) })) };
      }),
    }),

    request_human_handoff: tool({
      description:
        'Pass the conversation to a person and silence the assistant. Use it for: customer asks for a person, legal/safety/complaint topics, ' +
        'financing terms or negotiation, or anything you are unsure about. After calling it, send nothing more.',
      inputSchema: requestHumanHandoffInput,
      execute: (args) => traced('request_human_handoff', { reason: args.reason, urgency: args.urgency }, async () => {
        const r = await ctx.deps.handoff({ reason: args.reason, summary: args.summary, urgency: args.urgency });
        state.handedOff = true;
        return { ok: true as const, inbox_item_id: r.inboxItemId, note: 'A rep has been notified. Do not message the customer further.' };
      }),
    }),

    check_inventory: tool({
      description:
        'Live inventory lookup. The ONLY source for price, MSRP, incentives and availability. Only state numbers and availability that this tool returned in this turn. ' +
        'Statuses other than "available" mean you must not say the vehicle is in stock.',
      inputSchema: checkInventoryInput,
      execute: (args) => traced('check_inventory', { ...args }, async () => {
        const rows = await ctx.deps.searchInventory(args);
        if (rows.length === 0) return fail('no_match', 'No matching vehicles. Do not say it is available; offer to search alternatives or have a rep check incoming stock.');
        mergeVehicles(ctx.evidence, rows);
        return {
          ok: true as const,
          as_of: now().toISOString(),
          vehicles: rows.slice(0, args.limit).map((r) => ({
            vin: r.vin.toUpperCase(), year: r.year, make: r.make, model: r.model, trim: r.trim ?? null, condition: r.condition ?? null,
            mileage: r.mileage ?? null, status: r.status, price_cents: r.priceCents ?? null, msrp_cents: r.msrpCents ?? null, incentive_cents: r.incentiveCents ?? [],
          })),
        };
      }),
    }),

    book_test_drive: tool({
      description:
        'Request a test drive for a specific VIN at a specific time. Returns "confirmed" only if the calendar accepted it; otherwise "requested" (a rep will confirm) or "unavailable" with alternatives. ' +
        'Do not tell the customer it is confirmed unless this returned "confirmed".',
      inputSchema: bookTestDriveInput,
      execute: (args) => traced('book_test_drive', { vin: args.vin, slot_start: args.slot_start }, async () => {
        const start = new Date(args.slot_start);
        if (start.getTime() - now().getTime() < 60 * 60_000) return fail('slot_too_soon', 'Book at least one hour ahead, or hand off to a rep for same-hour visits.');
        const r = await ctx.deps.bookTestDrive({ vin: args.vin, slotStart: start, durationMin: args.duration_min, notes: args.notes });
        if (r.status === 'unavailable') return fail('slot_unavailable', `${r.reason} Alternatives: ${r.alternatives.join(', ') || 'none'}.`, true);
        ctx.evidence.appointments.push({ startsAt: start.toISOString(), vin: args.vin, status: r.status });
        return { ok: true as const, status: r.status, appointment_id: r.appointmentId };
      }),
    }),

    request_trade_in_appraisal: tool({
      description:
        'Ask the used-car team to appraise the customer\'s trade-in. This does NOT produce a value: never quote or estimate trade value, only say an appraisal is requested and when to expect it.',
      inputSchema: requestTradeInAppraisalInput,
      execute: (args) => traced('request_trade_in_appraisal', { year: args.year, make: args.make, model: args.model }, async () => {
        const r = await ctx.deps.requestAppraisal(args);
        return { ok: true as const, appraisal_id: r.appraisalId, expected_response_hours: r.expectedResponseHours, note: 'Do not state any trade value.' };
      }),
    }),

    start_prequal: tool({
      description:
        'Create a secure pre-qualification link. NEVER ask for SSN, date of birth, income or card numbers in chat; send the link instead via send_message. ' +
        'Do not imply approval, rates or terms.',
      inputSchema: startPrequalInput,
      execute: (args) => traced('start_prequal', { ...args }, async () => {
        const r = await ctx.deps.createPrequalLink({ termMonths: args.desired_term_months, downPaymentCents: args.down_payment_cents, vin: args.vehicle_vin });
        return { ok: true as const, url: r.url, expires_at: r.expiresAt, note: 'Share only this link. Do not mention approval, APR or payment.' };
      }),
    }),
  };
}
export type AgentTools = ReturnType<typeof createAgentTools>;
