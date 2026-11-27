/**
 * Edge Function: morning-briefing
 *
 * Triggered by pg_cron -> public.kick_briefing_worker() -> pg_net POST (every 15 min), or manually with the service key.
 *   1. enqueue_due_briefings() already ran in SQL (store-local time window); this function only claims `pending` rows.
 *   2. For each claimed briefing: build_briefing_items() -> narrate -> suggested drafts (gated) -> deliver.
 *
 * Auth: Bearer SUPABASE_SERVICE_ROLE_KEY only (this endpoint is not user-callable).
 * Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, optional AI_GATEWAY_API_KEY (LLM). Without the LLM the briefing
 * still ships using deterministic text.
 *
 * `makeDeps` below is the integration surface (see SPEC.md "Build order"); gate inputs use prepareFromGateContext; the
 * DB-facing methods are thin RPC/table calls; the LLM calls are injected so tests never hit a network.
 */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { processBriefings, DEFAULT_BRIEFING_CONFIG, type BriefingDeps, type BriefingItemRow, type Narration, type NarrationInput, type PreparedDraft } from './process.ts';
import type { ComplianceDecision, GateInput } from '../_shared/before-send.ts';
import { gateInputFromContext, type GateContextRow } from '../_shared/gate-context.ts';

/** Loads gate inputs for a lead; implemented once and shared with the agent runner (see SPEC build step 3). */
export type PrepareDraft = (db: SupabaseClient<any, any, any>, item: BriefingItemRow, body: string, now: Date) => Promise<PreparedDraft | null>;

/** Dry-run compliance bound to one lead/number: the SAME SQL function production sends use, with commit=false. */
export function dryRunFor(db: SupabaseClient<any, any, any>, t: PreparedDraft['target']): (i: GateInput) => Promise<ComplianceDecision> {
  return async (i) => {
    const { data, error } = await db.rpc('can_send', {
      p_dealer_id: t.dealerId, p_contact_id: t.contactId, p_channel: i.channel, p_purpose: i.purpose, p_kind: i.kind,
      p_number_id: t.numberId, p_body: i.body, p_lead_id: t.leadId, p_actor: i.actor, p_commit: false, p_now: i.now.toISOString(),
    });
    if (error) throw new Error(`can_send: ${error.message}`);
    return data as ComplianceDecision;
  };
}

/**
 * The real `prepare`: route (pick_send_route) + one get_gate_context round trip -> GateInput. Same mapping as the
 * outbound sweeper and the agent runner, so a suggested draft is judged on exactly the facts a send would be.
 */
export const prepareFromGateContext: PrepareDraft = async (db, item, body, now) => {
  const { data: lead, error } = await db.from('leads').select('id, dealer_id, contact_id').eq('id', item.lead_id).single();
  if (error || !lead) return null;
  const l = lead as { id: string; dealer_id: string; contact_id: string };
  const { data: routes } = await db.rpc('pick_send_route', { p_dealer_id: l.dealer_id, p_contact_id: l.contact_id, p_preferred: null });
  const route = (routes as { channel: GateInput['channel']; number_id: string }[] | null)?.[0];
  if (!route) return null;                                              // unreachable / opted out: no suggested draft
  const { data: ctx, error: e2 } = await db.rpc('get_gate_context', { p_dealer_id: l.dealer_id, p_contact_id: l.contact_id, p_lead_id: l.id, p_channel: route.channel, p_now: now.toISOString() });
  if (e2 || !ctx) return null;
  const c = ctx as GateContextRow;
  const recentInbound = c.latest_inbound && now.getTime() - new Date(c.latest_inbound.at).getTime() < 24 * 3_600_000;
  const target = { dealerId: l.dealer_id, leadId: l.id, contactId: l.contact_id, numberId: route.number_id };
  const gate = gateInputFromContext(c, { actor: 'ai', channel: route.channel, purpose: 'conversational', kind: recentInbound ? 'reply' : 'followup', body, now, inboundText: recentInbound ? c.latest_inbound!.body : null });
  return { gate, target, chain: { canSendDryRun: dryRunFor(db, target) } };
};

export interface Llm {
  narrate(input: NarrationInput): Promise<Narration>;
  draftReply(ctx: { kind: string; reason: string; lastInbound: string | null; dealerName: string }): Promise<string | null>;
}

/** Placeholder LLM: returns nothing so the deterministic fallback is used. Replace with an AI SDK `generateObject` call. */
export const noopLlm: Llm = {
  narrate: async () => ({ narrative: '' }),
  draftReply: async () => null,
};

export function makeDeps(db: SupabaseClient<any, any, any>, llm: Llm, prepare: PrepareDraft): BriefingDeps {
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const { data, error } = await db.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data as T;
  };
  return {
    claim: (limit) => rpc('claim_pending_briefings', { p_limit: limit }),
    async build(b) {
      await rpc('build_briefing_items', { p_briefing_id: b.id });
      const [{ data: items, error: e1 }, { data: br, error: e2 }] = await Promise.all([
        db.from('briefing_items').select('id, rank, lead_id, kind, score, reason_text, evidence').eq('briefing_id', b.id).order('rank'),
        db.from('daily_briefings').select('facts').eq('id', b.id).single(),
      ]);
      if (e1 || e2) throw new Error(`load briefing: ${(e1 ?? e2)!.message}`);
      return { items: (items ?? []) as BriefingItemRow[], facts: br!.facts };
    },
    narrate: (input) => llm.narrate(input),
    async draftReply(item) {
      const { data } = await db.from('leads').select('last_inbound_text, dealers(name)').eq('id', item.lead_id).single();
      const d = data as { last_inbound_text?: string | null; dealers?: { name?: string } | null } | null;
      return llm.draftReply({ kind: item.kind, reason: item.reason_text, lastInbound: d?.last_inbound_text ?? null, dealerName: d?.dealers?.name ?? 'the dealership' });
    },
    prepareDraft: (item, body, now) => prepare(db, item, body, now),
    async insertDraft({ item, target, gate, outcome }) {
      const { data, error } = await db.from('outbound_drafts').insert({
        dealer_id: target.dealerId, lead_id: target.leadId, contact_id: target.contactId, number_id: target.numberId, channel: gate.channel, purpose: gate.purpose, kind: gate.kind, actor: 'ai',
        body_ai: outcome.body, status: 'awaiting_review', release_at: null, evidence: gate.evidence, chain_version: outcome.chainVersion,
      }).select('id').single();
      if (error) throw new Error(`insert draft: ${error.message}`);
      return data!.id as string;
    },
    async linkDraft(itemId, draftId) { await db.from('briefing_items').update({ draft_id: draftId }).eq('id', itemId); },
    async saveReady(id, narrative, itemTexts) {
      await db.from('daily_briefings').update({ narrative }).eq('id', id);
      for (const [rank, text] of Object.entries(itemTexts)) await db.from('briefing_items').update({ reason_text: text }).eq('briefing_id', id).eq('rank', Number(rank));
    },
    async deliver() { /* In-app delivery is the table itself (Realtime on daily_briefings). Add web push / email digest here. */ },
    async markDelivered(id) { await db.from('daily_briefings').update({ status: 'delivered', delivered_at: new Date().toISOString() }).eq('id', id); },
    async markFailed(id, error, final) { await db.from('daily_briefings').update({ status: final ? 'failed' : 'pending', error }).eq('id', id); },
    now: () => new Date(),
    log: (event, data) => console.log(JSON.stringify({ fn: 'morning-briefing', event, ...data })),
  };
}

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } });
  // Finish during the build: a real Llm (narration + draft wording). Gate inputs come from get_gate_context.
  const deps = makeDeps(db, noopLlm, prepareFromGateContext);
  const summary = await processBriefings(deps, DEFAULT_BRIEFING_CONFIG);
  return Response.json(summary);
});
