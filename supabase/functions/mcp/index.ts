/**
 * Edge Function: mcp. Deploy with `verify_jwt = false` (it authenticates its own `sos_` keys); it talks to Postgres with
 * the service role and every mcp_* SQL function re-checks scope and visibility. Connect from an MCP client with the
 * function URL and the header `Authorization: Bearer sos_...` (created in Settings -> API keys; shown once).
 */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { handleMcpRequest, type McpDeps } from './handler.ts';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } });
const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
};
const deps: McpDeps = {
  rpc,
  async verifyKey(key) {
    const rows = await rpc<{ key_id: string; dealer_id: string; acting_user_id: string; role: 'viewer' | 'sales' | 'manager' | 'admin'; scopes: string[] }[]>('verify_mcp_api_key', { p_key: key });
    return rows?.[0] ?? null;
  },
  async audit(a) {
    await rpc('mcp_audit', {
      p_dealer_id: a.principal.dealerId, p_actor_kind: a.principal.actorKind, p_api_key_id: a.principal.apiKeyId ?? null,
      p_staff_identity_id: a.principal.staffIdentityId ?? null, p_user_id: a.principal.userId, p_tool: a.tool, p_args: a.args,
      p_result_code: a.resultCode, p_lead_id: a.leadId ?? null, p_draft_id: a.draftId ?? null,
    });
  },
};
Deno.serve((req) => handleMcpRequest(req, deps));
