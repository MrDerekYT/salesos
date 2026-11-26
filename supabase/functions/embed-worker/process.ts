/**
 * Embed worker loop (pure; the Edge Function wires the RPCs). claim -> batch embed -> complete (hash-checked) / fail.
 * No provider => defer the queue (FTS keeps working); a non-retryable provider error (wrong dimensions) also defers,
 * because retrying a misconfiguration only burns attempts.
 */
import { toPgVector, EmbeddingError, type EmbeddingProvider } from '../_shared/embeddings.ts';

export interface EmbedJob { target_kind: 'kb' | 'vehicle'; target_id: string; dealer_id: string; content: string; content_hash: string; attempts: number }
export interface EmbedWorkerDeps {
  claim(limit: number): Promise<EmbedJob[]>;
  complete(job: EmbedJob, vectorLiteral: string, model: string): Promise<'stored' | 'stale' | 'missing'>;
  fail(job: EmbedJob, error: string): Promise<void>;
  defer(minutes: number, reason: string): Promise<number>;
  log?(event: string, data: Record<string, unknown>): void;
}
export interface EmbedSummary { claimed: number; stored: number; stale: number; missing: number; failed: number; deferred: number; mode: 'embed' | 'fts_only' }

export async function runEmbedWorker(deps: EmbedWorkerDeps, provider: EmbeddingProvider | null, cfg = { batch: 64, deferMinutes: 60 }): Promise<EmbedSummary> {
  const sum: EmbedSummary = { claimed: 0, stored: 0, stale: 0, missing: 0, failed: 0, deferred: 0, mode: provider ? 'embed' : 'fts_only' };
  if (!provider) {
    sum.deferred = await deps.defer(cfg.deferMinutes, 'no embeddings provider configured (FTS-only mode)');
    return sum;
  }
  const jobs = await deps.claim(cfg.batch);
  sum.claimed = jobs.length;
  if (jobs.length === 0) return sum;
  let vectors: number[][];
  try {
    vectors = await provider.embed(jobs.map((j) => j.content));
  } catch (e) {
    const err = e as Error;
    if (err instanceof EmbeddingError && !err.retryable) {
      for (const j of jobs) await deps.fail(j, err.message);      // releases the locks
      sum.deferred = await deps.defer(cfg.deferMinutes, `provider misconfigured: ${err.message}`);
      sum.failed = jobs.length;
      deps.log?.('embed_misconfigured', { error: err.message });
      return sum;
    }
    for (const j of jobs) await deps.fail(j, err.message);
    sum.failed = jobs.length;
    return sum;
  }
  for (let i = 0; i < jobs.length; i++) {
    const r = await deps.complete(jobs[i], toPgVector(vectors[i]), provider.model);
    sum[r]++;
  }
  deps.log?.('embed_batch', { ...sum });
  return sum;
}
