/**
 * search_knowledge implementation: embed the query (bounded by a timeout), call match_kb() (hybrid RRF in Postgres),
 * map rows to the agent tool shape. If embedding is unavailable or slow, the SAME RPC runs FTS-only, so the agent
 * always gets an answer from the dealer's own documents. Pattern credit: hybrid retrieval with citations (wacrm,
 * AgentSDR; MIT). Code is original.
 */
import type { KnowledgeHit } from './agent-tools.ts';
import { toPgVector, type EmbeddingProvider } from './embeddings.ts';

export interface MatchKbRow {
  source_kind: 'kb' | 'vehicle'; chunk_id: string; document_id: string | null; vehicle_id: string | null; title: string; kind: string;
  content: string; source_uri: string | null; document_version: number | null; rrf_score: number; fts_rank: number | null; vec_rank: number | null;
  similarity: number | null; mode: 'hybrid' | 'fts_only';
}
export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>;

export interface KnowledgeSearchOptions {
  rpc: Rpc;
  dealerId: string;
  embed: EmbeddingProvider | null;
  embedTimeoutMs?: number;
  includeVehicles?: boolean;
  log?: (event: string, data: Record<string, unknown>) => void;
}

export async function withTimeout<T>(ms: number, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const ac = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      run(ac.signal),
      new Promise<never>((_, rej) => { timer = setTimeout(() => { ac.abort(); rej(new Error(`timeout after ${ms}ms`)); }, ms); }),
    ]);
  } finally { if (timer) clearTimeout(timer); }
}

/** Excerpt around the first query term so the model sees the relevant sentence, not the chunk's first 600 chars. */
export function excerpt(content: string, query: string, max = 600): string {
  if (content.length <= max) return content;
  const terms = query.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 4);
  const lc = content.toLowerCase();
  const hit = terms.map((t) => lc.indexOf(t)).filter((i) => i >= 0).sort((a, b) => a - b)[0] ?? 0;
  const start = Math.max(0, Math.min(hit - 120, content.length - max));
  return (start > 0 ? '…' : '') + content.slice(start, start + max - 1).trim() + (start + max - 1 < content.length ? '…' : '');
}

export function createKnowledgeSearch(o: KnowledgeSearchOptions) {
  return async function searchKnowledge(a: { query: string; kinds?: string[]; topK: number }): Promise<KnowledgeHit[]> {
    let vector: number[] | null = null;
    if (o.embed) {
      try {
        [vector] = await withTimeout(o.embedTimeoutMs ?? 1500, (signal) => o.embed!.embed([a.query], { signal }));
      } catch (e) {
        o.log?.('rag_embed_fallback', { error: (e as Error).message });   // degrade to FTS-only; never fail the turn
      }
    }
    const rows = await o.rpc<MatchKbRow[]>('match_kb', {
      p_dealer_id: o.dealerId, p_query: a.query,
      p_query_embedding: vector ? toPgVector(vector) : null,
      p_embedding_model: vector ? o.embed!.model : null,
      p_kinds: a.kinds?.length ? a.kinds : null,
      p_match_count: a.topK,
      p_include_vehicles: o.includeVehicles ?? true,
    }) ?? [];
    o.log?.('rag_search', { mode: rows[0]?.mode ?? (vector ? 'hybrid' : 'fts_only'), hits: rows.length });
    return rows.slice(0, a.topK).map((r) => ({
      id: r.chunk_id, title: r.title, kind: r.kind, excerpt: excerpt(r.content, a.query), score: r.rrf_score,
      citation: { sourceKind: r.source_kind, chunkId: r.chunk_id, documentId: r.document_id, vehicleId: r.vehicle_id, documentVersion: r.document_version, title: r.title, score: r.rrf_score },
    }));
  };
}

/** Shape record_draft_citations() expects. */
export function citationsPayload(k: NonNullable<import('./before-send.ts').TurnEvidence['knowledge']>): Record<string, unknown>[] {
  return k.map((c, i) => ({ source_kind: c.sourceKind, chunk_id: c.chunkId, document_id: c.documentId, vehicle_id: c.vehicleId, document_version: c.documentVersion, rank: i + 1, score: c.score }));
}
