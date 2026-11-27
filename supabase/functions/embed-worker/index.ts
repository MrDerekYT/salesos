/**
 * Edge Function: embed-worker. Invoked by pg_cron -> kick_embed_worker() -> pg_net (only when the queue has due work).
 * Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY; optional EMBEDDINGS_API_KEY / EMBEDDINGS_BASE_URL / EMBEDDINGS_MODEL.
 * Without the embeddings key it defers the queue and match_kb() runs full-text only.
 */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { providerFromEnv } from '../_shared/embeddings.ts';
import { runEmbedWorker, type EmbedJob, type EmbedWorkerDeps } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } });
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const { data, error } = await db.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data as T;
  };
  const deps: EmbedWorkerDeps = {
    claim: (limit) => rpc<EmbedJob[]>('claim_embed_jobs', { p_limit: limit }),
    complete: (j, v, model) => rpc('complete_embed_job', { p_kind: j.target_kind, p_id: j.target_id, p_embedding: v, p_model: model, p_content_hash: j.content_hash }),
    fail: (j, e) => rpc('fail_embed_job', { p_kind: j.target_kind, p_id: j.target_id, p_error: e }),
    defer: (m, r) => rpc('defer_embed_jobs', { p_minutes: m, p_reason: r }),
    log: (event, data) => console.log(JSON.stringify({ fn: 'embed-worker', event, ...data })),
  };
  return Response.json(await runEmbedWorker(deps, providerFromEnv((k) => Deno.env.get(k))));
});
