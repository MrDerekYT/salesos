import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleMcpRequest, handleRpc, toolList, MCP_PROTOCOL_VERSION, type McpDeps } from '../../supabase/functions/mcp/handler.ts';
import { callCrmTool, mapDbError, redactArgs, CRM_TOOL_NAMES, type Principal } from '../../supabase/functions/_shared/crm-tools.ts';

const KEY = 'sos_' + 'a'.repeat(64);
const LEAD = '00000000-0000-4000-8000-000000000001';
const SCOPES = {
  viewer: ['leads:read', 'inventory:read'],
  sales: ['leads:read', 'inventory:read', 'leads:write', 'tasks:write', 'drafts:write'],
};
function mk(role: 'viewer' | 'sales' = 'sales', rpcImpl?: (fn: string, a: Record<string, unknown>) => unknown) {
  const calls: [string, Record<string, unknown>][] = [];
  const audits: any[] = [];
  const deps: McpDeps = {
    verifyKey: async (k) => (k === KEY ? { key_id: 'K', dealer_id: 'D', acting_user_id: 'U', role, scopes: SCOPES[role] } : null),
    rpc: async <T>(fn: string, a: Record<string, unknown>) => { calls.push([fn, a]); return (rpcImpl ? rpcImpl(fn, a) : { decision: 'applied' }) as T; },
    audit: async (a) => { audits.push(a); },
  };
  return { deps, calls, audits };
}
const post = (body: unknown, auth = `Bearer ${KEY}`) => new Request('https://x/functions/v1/mcp', { method: 'POST', headers: { authorization: auth, 'content-type': 'application/json' }, body: JSON.stringify(body) });

test('auth: missing / malformed / unknown key => 401 with WWW-Authenticate; GET => 405', async () => {
  const { deps } = mk();
  for (const a of ['', 'Bearer nope', `Bearer sos_${'b'.repeat(64)}`]) {
    const r = await handleMcpRequest(post({ jsonrpc: '2.0', id: 1, method: 'ping' }, a), deps);
    assert.equal(r.status, 401);
    assert.match(r.headers.get('www-authenticate')!, /Bearer/);
  }
  assert.equal((await handleMcpRequest(new Request('https://x', { method: 'GET' }), deps)).status, 405);
});

test('initialize, ping, notifications (202), batch rejected, unknown method, parse error', async () => {
  const { deps } = mk();
  const init = await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: MCP_PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: 't', version: '1' } } }), deps)).json();
  assert.equal(init.result.protocolVersion, MCP_PROTOCOL_VERSION);
  assert.deepEqual(init.result.capabilities, { tools: { listChanged: false } });
  assert.deepEqual((await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 2, method: 'ping' }), deps)).json()).result, {});
  assert.equal((await handleMcpRequest(post({ jsonrpc: '2.0', method: 'notifications/initialized' }), deps)).status, 202);
  assert.equal((await (await handleMcpRequest(post([{ jsonrpc: '2.0', id: 1, method: 'ping' }]), deps)).json()).error.code, -32600);
  assert.equal((await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 3, method: 'resources/list' }), deps)).json()).error.code, -32601);
  const bad = new Request('https://x', { method: 'POST', headers: { authorization: `Bearer ${KEY}` }, body: '{oops' });
  assert.equal((await (await handleMcpRequest(bad, deps)).json()).error.code, -32700);
});

test('tools/list is filtered by role and exposes strict JSON schemas', async () => {
  assert.deepEqual(toolList(SCOPES.viewer).map((t) => t.name).sort(), ['find_leads', 'get_lead', 'list_attention', 'search_inventory']);
  const all = toolList(SCOPES.sales);
  assert.deepEqual(all.map((t) => t.name).sort(), [...CRM_TOOL_NAMES].sort());
  const move = all.find((t) => t.name === 'move_stage')!;
  assert.equal((move.inputSchema as any).additionalProperties, false);
  assert.deepEqual((move.inputSchema as any).required.sort(), ['lead_id', 'stage']);
  assert.equal(all.find((t) => t.name === 'get_lead')!.annotations.readOnlyHint, true);
  assert.match(all.find((t) => t.name === 'draft_message')!.description, /never sent/);
});

test('tools/call: identity comes from the key; forged dealer_id is rejected by the strict schema', async () => {
  const { deps, calls, audits } = mk();
  const ok = await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'move_stage', arguments: { lead_id: LEAD, stage: 'negotiating' } } }), deps)).json();
  assert.equal(ok.result.isError, false);
  assert.deepEqual(calls[0], ['mcp_move_stage', { p_dealer_id: 'D', p_role: 'sales', p_user_id: 'U', p_lead_id: LEAD, p_stage: 'negotiating', p_reason: null }]);
  assert.equal(audits[0].resultCode, 'ok');
  assert.equal(audits[0].leadId, LEAD);
  const forged = await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'get_lead', arguments: { lead_id: LEAD, dealer_id: 'OTHER' } } }), deps)).json();
  assert.equal(forged.result.isError, true);
  assert.equal(forged.result.structuredContent.error.code, 'invalid');
  assert.equal(calls.length, 1);
  assert.equal(audits[1].resultCode, 'invalid');
});

test('viewer cannot write (checked before the database); unknown tool is a protocol error', async () => {
  const { deps, calls, audits } = mk('viewer');
  const r = await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'move_stage', arguments: { lead_id: LEAD, stage: 'won' } } }), deps)).json();
  assert.equal(r.result.structuredContent.error.code, 'forbidden');
  assert.equal(calls.length, 0);
  assert.equal(audits[0].resultCode, 'forbidden');
  const u = await (await handleMcpRequest(post({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'send_sms', arguments: {} } }), deps)).json();
  assert.equal(u.error.code, -32602);
});

test('database errors map to safe codes (no SQL text leaks); not_found hides existence', async () => {
  assert.deepEqual(mapDbError('not_found: lead'), { ok: false, code: 'not_found', message: 'Not found (or not visible to you).' });
  assert.equal(mapDbError('forbidden: role viewer lacks scope leads:write').code, 'forbidden');
  assert.equal(mapDbError('invalid: due_at must be within 90 days').code, 'invalid');
  assert.equal(mapDbError('unknown stage teleported').code, 'invalid');
  const internal = mapDbError('duplicate key value violates unique constraint "x_pkey"');
  assert.deepEqual([internal.code, /duplicate/.test(internal.message)], ['internal', false]);
  const { deps } = mk('sales', () => { throw new Error('not_found: lead'); });
  const r = await handleRpc({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_lead', arguments: { lead_id: LEAD } } }, { dealerId: 'D', userId: 'U', role: 'sales', scopes: SCOPES.sales, actorKind: 'api_key' }, deps);
  assert.equal((r as any).result.isError, true);
});

test('draft_message: refusal from SQL becomes a tool error; audit never stores the body', async () => {
  const p: Principal = { dealerId: 'D', userId: 'U', role: 'sales', scopes: SCOPES.sales, actorKind: 'api_key', apiKeyId: 'K' };
  const refused = mk('sales', () => ({ ok: false, code: 'dnc_active', message: 'The contact opted out.' }));
  const r = await callCrmTool(p, 'draft_message', { lead_id: LEAD, body: 'Hi Sarah, my cell is 555-1234' }, refused.deps);
  assert.deepEqual([r.ok, !r.ok && r.code], [false, 'invalid']);
  assert.equal(refused.audits[0].args.body, undefined);
  assert.equal(refused.audits[0].args.body_len, 29);
  const ok = mk('sales', () => ({ ok: true, draft_id: 'DR9', status: 'awaiting_review' }));
  await callCrmTool(p, 'draft_message', { lead_id: LEAD, body: 'Hello' }, ok.deps);
  assert.equal(ok.audits[0].draftId, 'DR9');
  assert.deepEqual(redactArgs('find_leads', { query: 'sarah' }), { query: 's…' });
});

test('search_inventory is dealer-scoped and takes no user id', async () => {
  const { deps, calls } = mk('viewer', () => []);
  await callCrmTool({ dealerId: 'D', userId: 'U', role: 'viewer', scopes: SCOPES.viewer, actorKind: 'api_key' }, 'search_inventory', { model: 'tacoma', max_price_cents: 3500000 }, deps);
  assert.equal(calls[0][0], 'mcp_search_inventory');
  assert.equal('p_user_id' in calls[0][1], false);
  assert.equal(calls[0][1].p_limit, 5);
});
