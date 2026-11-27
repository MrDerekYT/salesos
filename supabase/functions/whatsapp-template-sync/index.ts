/** Edge Function: whatsapp-template-sync (service role; pg_cron hourly). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, META_ACCESS_TOKEN, META_API_VERSION. */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { rpcFromClient } from '../_shared/runtime.ts';
import { syncTemplates } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const token = Deno.env.get('META_ACCESS_TOKEN');
  if (!token) return Response.json({ skipped: 'META_ACCESS_TOKEN not set' });
  const rpc = rpcFromClient(createClient(Deno.env.get('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
  return Response.json(await syncTemplates(rpc, { accessToken: token, apiVersion: Deno.env.get('META_API_VERSION') ?? undefined }, new Date()));
});
