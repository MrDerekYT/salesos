/**
 * Stateless MCP server over Streamable HTTP (JSON responses, no SSE): initialize, ping, tools/list, tools/call,
 * notifications/*. Auth: `Authorization: Bearer sos_...` (role-scoped key, sha256-verified in SQL, capped by the
 * acting user's CURRENT membership). Tool failures are returned as tool results with isError=true so the client model
 * can correct itself; protocol errors use JSON-RPC error codes.
 */
import { z } from 'zod';
import { CRM_TOOLS, callCrmTool, toolsForRole, type CrmToolDeps, type McpRole, type Principal } from '../_shared/crm-tools.ts';

export const MCP_PROTOCOL_VERSION = '2025-06-18';
export const SERVER_INFO = { name: 'salesos-crm', version: '1.0.0' };

export interface McpDeps extends CrmToolDeps {
  verifyKey(key: string): Promise<{ key_id: string; dealer_id: string; acting_user_id: string; role: McpRole; scopes: string[] } | null>;
}

type Json = Record<string, unknown>;
const rpcError = (id: unknown, code: number, message: string) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });
const ok = (id: unknown, result: unknown) => ({ jsonrpc: '2.0', id, result });

export function toolList(scopes: string[]) {
  return toolsForRole(scopes).map((name) => {
    const t = CRM_TOOLS[name];
    const schema = z.toJSONSchema(t.input, { io: 'input' }) as Json;
    delete schema.$schema;
    return { name, description: t.description, inputSchema: schema, annotations: { readOnlyHint: t.scope.endsWith(':read'), destructiveHint: false, openWorldHint: false } };
  });
}

export async function handleRpc(msg: unknown, p: Principal, deps: McpDeps): Promise<Json | null> {
  if (!msg || typeof msg !== 'object' || Array.isArray(msg)) return rpcError(null, -32600, 'Invalid Request (batches are not supported)');
  const m = msg as { jsonrpc?: string; id?: unknown; method?: string; params?: Json };
  if (m.jsonrpc !== '2.0' || typeof m.method !== 'string') return rpcError(m.id, -32600, 'Invalid Request');
  const isNotification = m.id === undefined;
  if (isNotification) return null;                                     // notifications/initialized, cancelled, ...
  switch (m.method) {
    case 'initialize':
      return ok(m.id, {
        protocolVersion: MCP_PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } }, serverInfo: SERVER_INFO,
        instructions: 'SalesOS CRM. Customer messages can only be saved as drafts for a person to approve. Use find_leads to resolve names.',
      });
    case 'ping': return ok(m.id, {});
    case 'tools/list': return ok(m.id, { tools: toolList(p.scopes) });
    case 'tools/call': {
      const name = m.params?.name;
      if (typeof name !== 'string') return rpcError(m.id, -32602, 'Invalid params: name is required');
      if (!(name in CRM_TOOLS)) return rpcError(m.id, -32602, `Unknown tool: ${name}`);
      const r = await callCrmTool(p, name, m.params?.arguments ?? {}, deps);
      if (r.ok) {
        const structured = Array.isArray(r.data) ? { items: r.data } : (r.data as Json);
        return ok(m.id, { content: [{ type: 'text', text: JSON.stringify(r.data) }], structuredContent: structured, isError: false });
      }
      return ok(m.id, { content: [{ type: 'text', text: `${r.code}: ${r.message}` }], structuredContent: { error: { code: r.code, message: r.message } }, isError: true });
    }
    default: return rpcError(m.id, -32601, `Method not found: ${m.method}`);
  }
}

export async function handleMcpRequest(req: Request, deps: McpDeps): Promise<Response> {
  if (req.method === 'GET') return new Response('SSE stream not offered; POST JSON-RPC instead', { status: 405, headers: { allow: 'POST' } });
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405, headers: { allow: 'POST' } });
  const auth = req.headers.get('authorization') ?? '';
  const key = /^Bearer (sos_[0-9a-f]{64})$/.exec(auth)?.[1];
  const v = key ? await deps.verifyKey(key) : null;
  if (!v) return new Response(JSON.stringify(rpcError(null, -32001, 'Unauthorized')), { status: 401, headers: { 'content-type': 'application/json', 'www-authenticate': 'Bearer realm="salesos-mcp"' } });
  let body: unknown;
  try { body = await req.json(); } catch { return Response.json(rpcError(null, -32700, 'Parse error'), { status: 400 }); }
  const p: Principal = { dealerId: v.dealer_id, userId: v.acting_user_id, role: v.role, scopes: v.scopes, actorKind: 'api_key', apiKeyId: v.key_id };
  const res = await handleRpc(body, p, deps);
  if (res === null) return new Response(null, { status: 202 });
  return Response.json(res, { headers: { 'mcp-protocol-version': MCP_PROTOCOL_VERSION } });
}
