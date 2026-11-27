/**
 * agentphone-bridge: AgentPhone (agentphone-webhook -> public.messages / public.calls) as a first-class SalesOS AI channel.
 * A trigger on those tables queues each row in salesos_ai.agentphone_inbox; this worker drains it:
 *   inbound text  -> the same inbound pipeline as Twilio/WhatsApp (contact + lead + thread, STOP/HELP/START first,
 *                    then the guardrailed agent + classification; every reply still goes through can_send)
 *   outbound text -> mirrored into salesos_ai.messages so pacing, spin checks and the agent's context see it
 *   call          -> lead activity; an opt-out said on the call becomes a DNC (STOP) or an urgent review item
 * agentphone-webhook itself is never changed.
 */
import { classifyInbound } from '../_shared/opt-out.ts';
import { processInbound, type InboundDeps } from '../_shared/inbound.ts';

export const AGENTPHONE_NUMBER = '+17542291849';

export interface InboxRow {
  id: string; kind: 'message' | 'call'; source_id: string; direction: string | null;
  from_number: string | null; to_number: string | null; body: string | null; created_at: string;
}

export async function runAgentPhoneBridge(deps: InboundDeps, limit = 20) {
  const rows = (await deps.rpc<InboxRow[]>('claim_agentphone_inbox', { p_limit: limit })) ?? [];
  const out = { claimed: rows.length, done: 0, ignored: 0, failed: 0 };
  for (const row of rows) {
    try {
      let status: 'done' | 'ignored' = 'done';
      let result: Record<string, unknown> = {};
      if (row.kind === 'message' && row.direction === 'outbound') {
        const id = await deps.rpc<string | null>('bridge_record_agentphone_outbound', { p_inbox_id: row.id });
        status = id ? 'done' : 'ignored'; result = { message_id: id };
      } else if (row.kind === 'message') {
        if (!row.from_number || row.from_number === AGENTPHONE_NUMBER) status = 'ignored';
        else {
          const r = await processInbound({
            channel: 'sms', to: row.to_number ?? AGENTPHONE_NUMBER, from: row.from_number, body: row.body ?? '',
            providerMessageId: `agentphone:${row.source_id}`, receivedAt: new Date(row.created_at), providerOptOut: null,
          }, deps);
          status = r.status === 'ignored' ? 'ignored' : 'done'; result = r as unknown as Record<string, unknown>;
        }
      } else {
        result = (await deps.rpc<Record<string, unknown> | null>('bridge_record_agentphone_call', { p_inbox_id: row.id })) ?? { status: 'ignored' };
        status = result.status === 'done' ? 'done' : 'ignored';
      }
      await deps.rpc('complete_agentphone_inbox', { p_id: row.id, p_status: status, p_result: result, p_error: null });
      if (row.kind === 'call' && status === 'done' && row.body) {
        const k = classifyInbound(row.body);
        if (k.level === 'stop' || k.level === 'probable_stop' || k.legalThreat) {
          await deps.rpc('bridge_call_opt_out', { p_inbox_id: row.id, p_level: k.level === 'stop' ? 'stop' : 'probable_stop', p_matched: k.matched ?? null });
        }
      }
      if (status === 'done') out.done++; else out.ignored++;
    } catch (e) {
      out.failed++;
      deps.log?.('agentphone_bridge_error', { inbox_id: row.id, error: (e as Error).message });
      await deps.rpc('complete_agentphone_inbox', { p_id: row.id, p_status: 'failed', p_result: null, p_error: (e as Error).message }).catch(() => undefined);
    }
  }
  return out;
}
