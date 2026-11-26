/** Edge Function: classify-worker (service role). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CLASSIFIER_MODEL or AGENT_MODEL (+ AI_GATEWAY_API_KEY). */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { runClassifyWorker } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const rpc = rpcFromClient(createClient(Deno.env.get('SUPABASE_URL')!, key, { auth: { persistSession: false } }));
  const modelId = Deno.env.get('CLASSIFIER_MODEL') ?? Deno.env.get('AGENT_MODEL') ?? null;
  return Response.json(await runClassifyWorker({ rpc, model: modelId, modelId, now: () => new Date(), log: jsonLog('classify-worker') }));
});
