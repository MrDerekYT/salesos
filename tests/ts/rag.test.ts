import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiCompatibleProvider, providerFromEnv, assertDims, EmbeddingError, EMBEDDING_DIM, toPgVector, type EmbeddingProvider } from '../../supabase/functions/_shared/embeddings.ts';
import { createKnowledgeSearch, excerpt, citationsPayload, type MatchKbRow } from '../../supabase/functions/_shared/rag.ts';
import { runEmbedWorker, type EmbedJob, type EmbedWorkerDeps } from '../../supabase/functions/embed-worker/process.ts';
import { createAgentTools, type AgentToolDeps } from '../../lib/agent/tools.ts';
import { emptyEvidence } from '../../supabase/functions/_shared/before-send.ts';

const vec = (seed: number) => Array.from({ length: EMBEDDING_DIM }, (_, i) => (i === seed ? 1 : 0));
const row = (o: Partial<MatchKbRow> = {}): MatchKbRow => ({
  source_kind: 'kb', chunk_id: 'c1', document_id: 'd1', vehicle_id: null, title: 'Trade-in policy', kind: 'trade_in', content: 'We appraise trade-ins in 24 hours.',
  source_uri: null, document_version: 3, rrf_score: 0.0325, fts_rank: 1, vec_rank: 2, similarity: 0.8, mode: 'hybrid', ...o,
});

test('provider: OpenAI-compatible request, results re-ordered by index, batching', async () => {
  const seen: { url: string; body: any; auth: string | null }[] = [];
  const p = openAiCompatibleProvider({ baseUrl: 'https://gw.example/v1/', apiKey: 'k', model: 'm', maxBatch: 2, fetch: async (url, init) => {
    const body = JSON.parse(String(init.body)); seen.push({ url, body, auth: new Headers(init.headers).get('authorization') });
    return new Response(JSON.stringify({ data: body.input.map((_: string, i: number) => ({ index: i, embedding: vec(i) })).reverse() }), { status: 200 });
  } });
  const out = await p.embed(['a', 'b', 'c']);
  assert.equal(seen.length, 2);
  assert.equal(seen[0].url, 'https://gw.example/v1/embeddings');
  assert.equal(seen[0].auth, 'Bearer k');
  assert.deepEqual(out.map((v) => v.indexOf(1)), [0, 1, 0]);
});

test('provider: wrong dimensions are a non-retryable error; 429/5xx retryable; network retryable', async () => {
  const bad = openAiCompatibleProvider({ baseUrl: 'x', apiKey: 'k', model: 'm', fetch: async () => new Response(JSON.stringify({ data: [{ index: 0, embedding: [1, 2, 3] }] })) });
  await assert.rejects(bad.embed(['a']), (e: EmbeddingError) => !e.retryable && /dimensions/.test(e.message));
  const limited = openAiCompatibleProvider({ baseUrl: 'x', apiKey: 'k', model: 'm', fetch: async () => new Response('slow down', { status: 429 }) });
  await assert.rejects(limited.embed(['a']), (e: EmbeddingError) => e.retryable);
  const auth = openAiCompatibleProvider({ baseUrl: 'x', apiKey: 'k', model: 'm', fetch: async () => new Response('no', { status: 401 }) });
  await assert.rejects(auth.embed(['a']), (e: EmbeddingError) => !e.retryable);
  const down = openAiCompatibleProvider({ baseUrl: 'x', apiKey: 'k', model: 'm', fetch: async () => { throw new Error('ECONNRESET'); } });
  await assert.rejects(down.embed(['a']), (e: EmbeddingError) => e.retryable);
  assert.throws(() => assertDims([vec(0)], 2), /1 vectors for 2/);
  assert.throws(() => assertDims([[...vec(0).slice(1), Number.NaN]], 1), /non-finite/);
});

test('providerFromEnv: no key => null (FTS-only mode); defaults otherwise', () => {
  assert.equal(providerFromEnv(() => undefined), null);
  const p = providerFromEnv((k) => ({ EMBEDDINGS_API_KEY: 'k' } as Record<string, string>)[k]);
  assert.equal(p?.model, 'text-embedding-3-small');
});

test('search: hybrid call passes the vector + model; hits carry citations', async () => {
  const calls: Record<string, unknown>[] = [];
  const embed: EmbeddingProvider = { model: 'm1', embed: async () => [vec(5)] };
  const search = createKnowledgeSearch({ dealerId: 'D', embed, rpc: async <T>(fn: string, a: Record<string, unknown>) => { calls.push({ fn, ...a }); return [row(), row({ chunk_id: 'c2', source_kind: 'vehicle', document_id: null, vehicle_id: 'v1', kind: 'vehicle_description' })] as T; } });
  const hits = await search({ query: 'trade in appraisal', kinds: ['trade_in'], topK: 4 });
  assert.equal(calls[0].fn, 'match_kb');
  assert.equal(calls[0].p_dealer_id, 'D');
  assert.equal(calls[0].p_embedding_model, 'm1');
  assert.equal(calls[0].p_query_embedding, toPgVector(vec(5)));
  assert.deepEqual(calls[0].p_kinds, ['trade_in']);
  assert.equal(hits[1].citation?.sourceKind, 'vehicle');
  assert.equal(hits[0].citation?.documentVersion, 3);
});

test('search: slow or failing embeddings degrade to FTS-only instead of failing the turn', async () => {
  const calls: Record<string, unknown>[] = [];
  const logs: string[] = [];
  const slow: EmbeddingProvider = { model: 'm1', embed: (_t, o) => new Promise((_, rej) => o?.signal?.addEventListener('abort', () => rej(new Error('aborted')))) };
  const search = createKnowledgeSearch({ dealerId: 'D', embed: slow, embedTimeoutMs: 20, log: (e) => logs.push(e), rpc: async <T>(_fn: string, a: Record<string, unknown>) => { calls.push(a); return [row({ mode: 'fts_only', vec_rank: null, similarity: null })] as T; } });
  const hits = await search({ query: 'saturday service hours', topK: 2 });
  assert.equal(calls[0].p_query_embedding, null);
  assert.equal(calls[0].p_embedding_model, null);
  assert.equal(calls[0].p_kinds, null);
  assert.equal(hits.length, 1);
  assert.ok(logs.includes('rag_embed_fallback'));
  const none = createKnowledgeSearch({ dealerId: 'D', embed: null, rpc: async <T>() => [] as T });
  assert.deepEqual(await none({ query: 'abc', topK: 3 }), []);
});

test('excerpt centers on the query term; citationsPayload ranks in order', () => {
  const long = 'x'.repeat(900) + ' The lien payoff letter is required for trade-ins. ' + 'y'.repeat(900);
  const e = excerpt(long, 'lien payoff', 200);
  assert.match(e, /lien payoff/);
  assert.ok(e.length <= 202);
  assert.equal(excerpt('short', 'q'), 'short');
  const p = citationsPayload([{ sourceKind: 'kb', chunkId: 'a', documentId: 'd', vehicleId: null, documentVersion: 1, title: 't', score: 0.1 }]);
  assert.deepEqual(p[0], { source_kind: 'kb', chunk_id: 'a', document_id: 'd', vehicle_id: null, document_version: 1, rank: 1, score: 0.1 });
});

test('search_knowledge tool records citable evidence once per chunk', async () => {
  const evidence = emptyEvidence();
  const deps = { searchKnowledge: async () => [
    { id: 'c1', title: 'Trade-in', kind: 'trade_in', excerpt: 'We appraise in 24h.', score: 0.03, citation: { sourceKind: 'kb' as const, chunkId: 'c1', documentId: 'd1', vehicleId: null, documentVersion: 2, title: 'Trade-in', score: 0.03 } },
  ] } as unknown as AgentToolDeps;
  const tools = createAgentTools({ dealerId: 'd', leadId: 'l', contactId: 'c', runId: 'r', turnKind: 'reply', evidence, deps, now: () => new Date() });
  const exec = tools.search_knowledge.execute as (a: unknown, o: unknown) => Promise<any>;
  await exec({ query: 'trade in', top_k: 4 }, { toolCallId: 't', messages: [] });
  await exec({ query: 'trade in again', top_k: 4 }, { toolCallId: 't2', messages: [] });
  assert.equal(evidence.knowledge?.length, 1);
  assert.equal(evidence.knowledge?.[0].documentVersion, 2);
});

function workerDeps(jobs: EmbedJob[], completeResult: (j: EmbedJob) => 'stored' | 'stale' | 'missing' = () => 'stored') {
  const log: string[] = [];
  const deps: EmbedWorkerDeps = {
    claim: async () => jobs,
    complete: async (j, v, m) => { log.push(`complete:${j.target_id}:${m}:${v.length > 1000}`); return completeResult(j); },
    fail: async (j, e) => { log.push(`fail:${j.target_id}:${e}`); },
    defer: async (m, r) => { log.push(`defer:${m}:${r}`); return 7; },
  };
  return { deps, log };
}
const job = (id: string): EmbedJob => ({ target_kind: 'kb', target_id: id, dealer_id: 'D', content: `text ${id}`, content_hash: 'h', attempts: 0 });

test('embed worker: no provider => defers the queue (FTS-only), claims nothing', async () => {
  const { deps, log } = workerDeps([job('a')]);
  const s = await runEmbedWorker(deps, null);
  assert.deepEqual([s.mode, s.deferred, s.claimed], ['fts_only', 7, 0]);
  assert.match(log[0], /^defer:60:no embeddings provider/);
});

test('embed worker: batch embed, hash-checked completion counts stored/stale', async () => {
  const { deps, log } = workerDeps([job('a'), job('b')], (j) => (j.target_id === 'b' ? 'stale' : 'stored'));
  const s = await runEmbedWorker(deps, { model: 'm', embed: async (t) => t.map((_, i) => vec(i)) });
  assert.deepEqual([s.claimed, s.stored, s.stale, s.failed], [2, 1, 1, 0]);
  assert.deepEqual(log, ['complete:a:m:true', 'complete:b:m:true']);
});

test('embed worker: transient error fails (backoff in SQL); misconfiguration also defers', async () => {
  const t = workerDeps([job('a')]);
  const s1 = await runEmbedWorker(t.deps, { model: 'm', embed: async () => { throw new EmbeddingError('HTTP 503', true); } });
  assert.deepEqual([s1.failed, s1.deferred], [1, 0]);
  const m = workerDeps([job('a')]);
  const s2 = await runEmbedWorker(m.deps, { model: 'm', embed: async () => { throw new EmbeddingError('embedding has 768 dimensions, expected 1536', false); } });
  assert.deepEqual([s2.failed, s2.deferred], [1, 7]);
  assert.ok(m.log.some((l) => l.startsWith('defer:60:provider misconfigured')));
});
