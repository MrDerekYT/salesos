/**
 * RPC-only wiring for the sweeper core (no table access from TS), shared by the Edge Function and the integration tests.
 * Sends go through the channel dispatcher (adapter registry chosen by channel_numbers.provider), keyed draft:<id> /
 * plan:<id>:<attempt> so a crash between "provider accepted" and "we recorded it" can never double-send.
 */
import type { ComplianceDecision, VehicleEvidence } from '../_shared/before-send.ts';
import type { GateContextRow } from '../_shared/gate-context.ts';
import type { Rpc } from '../_shared/crm-tools.ts';
import type { Dispatcher, SendTargetRow } from '../_shared/channels/dispatch.ts';
import { renderTemplate } from '../_shared/channels/whatsapp.ts';
import type { DuePlan, DueDraft, Route, SweeperDeps, TemplateChoice } from './process.ts';

const vehicleName = (v: VehicleEvidence | null) => (v ? [v.year, v.make, v.model].filter(Boolean).join(' ') : 'your vehicle');
const usd = (c: number | null | undefined) => (c == null ? '' : `$${Math.round(c / 100).toLocaleString('en-US')}`);
const USE: Record<string, string> = { price_drop: 'price_drop', service_due: 'service_due', lease_end: 'lease_end', stalled: 'reengage', promised: 'reengage', test_drive_noshow: 'reengage' };

/** Template parameter convention for SalesOS templates: {{1}} first name, {{2}} dealer, {{3}} vehicle, {{4}} price. */
export function templateParams(f: { firstName: string | null; vehicle: VehicleEvidence | null; dealerName: string }, count: number): string[] {
  return [f.firstName || 'there', f.dealerName, vehicleName(f.vehicle), usd(f.vehicle?.priceCents)].slice(0, count);
}

export function makeSweeperDeps(rpc: Rpc, dispatcher: Dispatcher, o: { now?: () => Date; log?: (e: string, d: Record<string, unknown>) => void } = {}): SweeperDeps {
  const now = o.now ?? (() => new Date());
  return {
    now,
    claimDrafts: (limit) => rpc<DueDraft[]>('claim_due_drafts', { p_limit: limit, p_now: now().toISOString() }),
    async releaseFacts(d) {
      const f = await rpc<{ lead_context_version: number | null; force_human: boolean; open_inbox: boolean; auto_send_enabled: boolean; handoff_hours: number; approved: boolean }>('sweeper_release_facts', { p_draft_id: d.id });
      return { leadContextVersion: f.lead_context_version, leadForceHuman: f.force_human, openInboxForLead: f.open_inbox, autoSendEnabled: f.auto_send_enabled, handoffHours: f.handoff_hours, approved: f.approved };
    },
    async setDraftStatus(id, status, patch = {}) {
      await rpc('set_draft_status', { p_draft_id: id, p_status: status, p_set_release: 'releaseAt' in patch, p_release_at: patch.releaseAt ?? null, p_veto_code: patch.vetoCode ?? null,
                                      p_reservation_id: patch.reservationId ?? null, p_body: patch.body ?? null, p_now: now().toISOString() });
    },
    gateContext: (dealerId, contactId, leadId, channel, n) => rpc<GateContextRow>('get_gate_context', { p_dealer_id: dealerId, p_contact_id: contactId, p_lead_id: leadId, p_channel: channel, p_now: n.toISOString() }),
    canSend: (t, i, commit) => rpc<ComplianceDecision>('can_send', {
      p_dealer_id: t.dealerId, p_contact_id: t.contactId, p_channel: i.channel, p_purpose: i.purpose, p_kind: i.kind, p_number_id: t.numberId,
      p_body: i.body, p_lead_id: t.leadId, p_actor: i.actor, p_commit: commit, p_idempotency_key: commit ? t.idempotencyKey ?? null : null, p_now: i.now.toISOString(),
    }),
    async providerSend(a) {
      const r = await dispatcher.send({ numberId: a.numberId, contactId: a.contactId, body: a.body, idempotencyKey: a.idempotencyKey, purpose: a.purpose, kind: a.kind, draftId: a.draftId, template: a.template ?? null });
      return r.ok ? { ok: true, providerMessageId: r.providerMessageId } : { ok: false, error: r.error, retryable: r.retryable };
    },
    async templateFor({ plan, route, facts }): Promise<TemplateChoice | 'not_needed' | null> {
      const t = await rpc<SendTargetRow | null>('get_send_target', { p_number_id: route.numberId, p_contact_id: plan.contact_id, p_now: now().toISOString() });
      if (t?.whatsapp_window_open) return 'not_needed';
      const row = (await rpc<{ name: string; language: string; body_text: string | null; param_count: number }[]>('pick_whatsapp_template', { p_number_id: route.numberId, p_use: USE[plan.trigger_kind] ?? 'reengage', p_purpose: plan.purpose }))[0];
      if (!row?.body_text) return null;
      const params = templateParams(facts, row.param_count);
      const body = renderTemplate(row.body_text, params);
      return body ? { name: row.name, language: row.language, params, body } : null;
    },
    finalize: async (draftId, r, body) => {
      await rpc('finalize_draft_send', { p_draft_id: draftId, p_ok: r.ok, p_provider_message_id: r.ok ? r.providerMessageId : null, p_error: r.ok ? null : r.error, p_body: body, p_now: now().toISOString() });
    },
    claimFollowups: (limit) => rpc<DuePlan[]>('claim_due_followups', { p_limit: limit, p_now: now().toISOString() }),
    async pickRoute(dealerId, contactId, preferred) {
      const rows = await rpc<{ channel: Route['channel']; number_id: string }[]>('pick_send_route', { p_dealer_id: dealerId, p_contact_id: contactId, p_preferred: preferred });
      return rows?.[0] ? { channel: rows[0].channel, numberId: rows[0].number_id } : null;
    },
    async followupFacts(p) {
      const f = await rpc<{ first_name: string | null; vehicle: { vin: string; status: VehicleEvidence['status']; price_cents: number | null; msrp_cents: number | null; year: number | null; make: string | null; model: string | null } | null }>('followup_facts', { p_plan_id: p.id });
      const v = f?.vehicle;
      return { firstName: f?.first_name ?? null, vehicle: v ? { vin: v.vin, status: v.status, priceCents: v.price_cents, msrpCents: v.msrp_cents, year: v.year, make: v.make, model: v.model } : null };
    },
    insertDraft: (a) => rpc<string>('agent_record_draft', { p: {
      dealer_id: a.plan.dealer_id, lead_id: a.plan.lead_id, contact_id: a.plan.contact_id, channel: a.route.channel, number_id: a.route.numberId, actor: 'ai',
      purpose: a.plan.purpose, kind: 'followup', body_ai: a.body, status: a.status, release_at: a.releaseAt, reservation_id: a.reservationId,
      evidence: { ...a.evidence, followup_plan_id: a.plan.id }, chain_version: a.chainVersion,
    } }),
    recordOutcome: (planId, outcome, code, notBefore, draftId) => rpc<string>('record_followup_outcome', { p_plan_id: planId, p_outcome: outcome, p_code: code, p_not_before: notBefore, p_draft_id: draftId, p_now: now().toISOString() }),
    log: o.log,
  };
}
