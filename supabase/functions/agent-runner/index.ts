/**
 * Edge Function: agent-runner (service role; pg_cron every 15 s via kick_agent_runner, plus a kick from each webhook).
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, AGENT_MODEL (AI Gateway "provider/model" id) + AI_GATEWAY_API_KEY,
 * PREQUAL_BASE_URL, EMBEDDINGS_* (optional, for hybrid RAG), provider credentials for auto-sends.
 * Without AGENT_MODEL every job is handed to a person (nothing is ever sent unattended by accident).
 */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { providerFromEnv } from '../_shared/embeddings.ts';
import { createKnowledgeSearch } from '../_shared/rag.ts';
import { runAgentWorker } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const env = (k: string) => Deno.env.get(k);
  const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
  const log = jsonLog('agent-runner');
  const modelId = env('AGENT_MODEL') ?? null;                      // a plain model id string resolves through the AI Gateway
  const embed = providerFromEnv(env);
  return Response.json(await runAgentWorker({
    rpc, dispatcher: dispatcherFromEnv(rpc, env, undefined, log), now: () => new Date(), sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    model: modelId, modelId, workerId: `edge-${crypto.randomUUID().slice(0, 8)}`, prequalBaseUrl: env('PREQUAL_BASE_URL') ?? null,
    searchKnowledge: (dealerId, a) => createKnowledgeSearch({ rpc, dealerId, embed, log })(a), log,
  }));
});
