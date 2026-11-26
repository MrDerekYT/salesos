/**
 * Classification worker. pg_cron (every 30 s) -> kick_classify_worker(). Only messages routed to the agent are queued
 * (apply_inbound_keyword): STOP/HELP/START/probable-stop never reach a model. Uses the phase-3 classify policy
 * (rule first, strict schema, grounding, context_version) and writes through record_classification.
 */
import type { LanguageModel } from 'ai';
import { classifyMessage, type ClassificationDecision } from '../_shared/classify.ts';
import type { Rpc } from '../_shared/crm-tools.ts';

export interface ClassifyJob { message_id: string; dealer_id: string; body: string; context_version: number; lead_stage: string; vehicle: string | null }
export interface ClassifyWorkerDeps { rpc: Rpc; model: LanguageModel | null; modelId: string | null; now(): Date; log?(e: string, d: Record<string, unknown>): void }

export async function runClassifyWorker(deps: ClassifyWorkerDeps, limit = 20): Promise<{ claimed: number; recorded: number; failed: number }> {
  const jobs = await deps.rpc<ClassifyJob[]>('claim_classification_jobs', { p_limit: limit, p_now: deps.now().toISOString() });
  const out = { claimed: jobs.length, recorded: 0, failed: 0 };
  for (const j of jobs) {
    let ok = false, err: string | null = null;
    try {
      const r = await classifyMessage({ messageId: j.message_id, text: j.body, contextVersion: j.context_version, leadStage: j.lead_stage, vehicle: j.vehicle }, {
        model: deps.model, modelId: deps.modelId ?? undefined,
        record: async (a: { messageId: string; decision: ClassificationDecision; contextVersion: number; model: string | null; promptVersion: string }) =>
          (await deps.rpc<{ classification_id: string; status: string }[]>('record_classification', {
            p_message_id: a.messageId, p_category: a.decision.category, p_confidence: a.decision.confidence, p_quote: a.decision.evidence_quote,
            p_rationale: a.decision.rationale, p_source: a.decision.source, p_model: a.model, p_prompt_version: a.promptVersion, p_context_version: a.contextVersion, p_now: deps.now().toISOString(),
          }))[0],
        recordFailure: (a) => deps.rpc<string>('record_classification_failure', { p_message_id: a.messageId, p_error: a.error, p_model: a.model, p_now: deps.now().toISOString() }),
      });
      // no model configured is a permanent condition: recorded once, not retried every 30 seconds
      ok = r.status !== 'failed' || r.error === 'no_model_configured';
      err = r.error ?? null;
    } catch (e) { err = (e as Error).message; }
    await deps.rpc('finish_classification_job', { p_message_id: j.message_id, p_ok: ok, p_error: err, p_now: deps.now().toISOString() });
    if (ok) out.recorded++; else out.failed++;
  }
  deps.log?.('classify_worker', out);
  return out;
}
