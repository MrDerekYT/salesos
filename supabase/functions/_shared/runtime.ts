/**
 * Edge-runtime wiring shared by the Phase-4 functions: service-role RPC, staff (CRM-by-text) deps, adapter registry and
 * dispatcher from env vars. Pure factories (no Deno globals) so tests can build the same objects with a fake env.
 */
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import type { Rpc } from './crm-tools.ts';
import type { StaffDeps } from './staff-commands.ts';
import type { Channel } from './before-send.ts';
import { createDispatcher, type Dispatcher } from './channels/dispatch.ts';
import { functionsUrl, registryFromEnv } from './channels/registry.ts';
import type { FetchLike } from './channels/types.ts';

export function rpcFromClient(db: SupabaseClient<any, any, any>): Rpc {
  return async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const { data, error } = await db.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data as T;
  };
}

export function staffDepsFromRpc(rpc: Rpc, now: () => Date = () => new Date()): StaffDeps {
  return {
    rpc, now,
    async resolveSender(dealerId: string, channel: Channel, address: string) {
      const rows = await rpc<{ staff_identity_id: string; user_id: string; role: 'viewer' | 'sales' | 'manager'; scopes: string[] }[]>('resolve_staff_sender', { p_dealer_id: dealerId, p_channel: channel, p_address: address });
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
}

export function dispatcherFromEnv(rpc: Rpc, get: (k: string) => string | undefined, f?: FetchLike, log?: (e: string, d: Record<string, unknown>) => void): Dispatcher {
  const fn = functionsUrl(get);
  return createDispatcher({ rpc, registry: registryFromEnv(get, f), unsubscribeBaseUrl: get('UNSUBSCRIBE_BASE_URL') ?? (fn ? `${fn}/unsubscribe` : null), log });
}

/** The URL a provider signed: PUBLIC_FUNCTIONS_URL/<fn> + the query string we received (req.url is internal behind the gateway). */
export function publicUrlFor(fnName: string, get: (k: string) => string | undefined): (req: Request) => string {
  return (req) => {
    const base = functionsUrl(get);
    const u = new URL(req.url);
    return base ? `${base}/${fnName}${u.search}` : req.url;
  };
}

export const jsonLog = (fn: string) => (event: string, data: Record<string, unknown>) => console.log(JSON.stringify({ fn, event, ...data }));
