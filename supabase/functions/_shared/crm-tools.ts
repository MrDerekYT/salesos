/**
 * CRM tool surface shared by the MCP server and staff texting (feature 7). One definition per tool: a strict Zod
 * schema, the scope it needs and the SQL function it maps to. Tenancy and identity come from the verified principal,
 * never from arguments. Customer-facing messages can only be created as drafts (mcp_draft_message => awaiting_review).
 * Every call is audited (args redacted: message bodies are replaced by their length). Pattern credit: Atomic CRM's MCP
 * server (MIT). Code is original.
 */
import { z } from 'zod';

export type McpRole = 'viewer' | 'sales' | 'manager' | 'admin';
export interface Principal {
  dealerId: string; userId: string; role: McpRole; scopes: string[];
  actorKind: 'api_key' | 'staff_sms' | 'staff_whatsapp' | 'staff_email';
  apiKeyId?: string | null; staffIdentityId?: string | null;
}
export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>;
export interface CrmToolDeps {
  rpc: Rpc;
  audit(a: { principal: Principal; tool: string; args: Record<string, unknown>; resultCode: string; leadId?: string | null; draftId?: string | null }): Promise<void>;
}

const STAGES = ['new', 'contacted', 'qualifying', 'qualified', 'test_drive', 'negotiating', 'won', 'lost'] as const;
const uuid = z.uuid();

export const CRM_TOOLS = {
  list_attention: {
    description: 'Leads that need attention right now (unanswered messages, hot leads gone quiet, no-shows, callbacks due, price drops), best first.',
    scope: 'leads:read',
    input: z.object({ limit: z.number().int().min(1).max(25).default(7) }).strict(),
    fn: 'mcp_list_attention', args: (a: { limit: number }) => ({ p_limit: a.limit }),
  },
  find_leads: {
    description: 'Find leads by customer name (at least 2 characters). Use it to turn a name into a lead_id.',
    scope: 'leads:read',
    input: z.object({ query: z.string().trim().min(2).max(80), limit: z.number().int().min(1).max(10).default(5) }).strict(),
    fn: 'mcp_find_leads', args: (a: { query: string; limit: number }) => ({ p_query: a.query, p_limit: a.limit }),
  },
  get_lead: {
    description: 'One lead: stage, vehicle, facts, reachability, the last 10 messages, open follow-ups and the last stage change.',
    scope: 'leads:read',
    input: z.object({ lead_id: uuid }).strict(),
    fn: 'mcp_get_lead', args: (a: { lead_id: string }) => ({ p_lead_id: a.lead_id }),
  },
  move_stage: {
    description: 'Move a lead to a pipeline stage. Recorded on the timeline as you; returns undo_activity_id.',
    scope: 'leads:write',
    input: z.object({ lead_id: uuid, stage: z.enum(STAGES), reason: z.string().trim().min(3).max(280).optional() }).strict(),
    fn: 'mcp_move_stage', args: (a: { lead_id: string; stage: string; reason?: string }) => ({ p_lead_id: a.lead_id, p_stage: a.stage, p_reason: a.reason ?? null }),
  },
  create_task: {
    description: 'Create a callback task on a lead (due within 90 days). Managers may assign it to another member.',
    scope: 'tasks:write',
    input: z.object({ lead_id: uuid, title: z.string().trim().min(3).max(200), due_at: z.iso.datetime({ offset: true }), assign_to: uuid.optional() }).strict(),
    fn: 'mcp_create_task', args: (a: { lead_id: string; title: string; due_at: string; assign_to?: string }) => ({ p_lead_id: a.lead_id, p_title: a.title, p_due_at: a.due_at, p_assign_to: a.assign_to ?? null }),
  },
  search_inventory: {
    description: 'Search available / in-transit inventory (sold, pending and held units are never returned).',
    scope: 'inventory:read',
    input: z.object({
      make: z.string().trim().max(40).optional(), model: z.string().trim().max(60).optional(),
      year_min: z.number().int().min(1980).max(2100).optional(), year_max: z.number().int().min(1980).max(2100).optional(),
      max_price_cents: z.number().int().positive().optional(), body_style: z.string().trim().max(40).optional(),
      condition: z.enum(['new', 'used', 'cpo']).optional(), limit: z.number().int().min(1).max(20).default(5),
    }).strict(),
    fn: 'mcp_search_inventory',
    args: (a: { make?: string; model?: string; year_min?: number; year_max?: number; max_price_cents?: number; body_style?: string; condition?: string; limit: number }) => ({
      p_make: a.make ?? null, p_model: a.model ?? null, p_year_min: a.year_min ?? null, p_year_max: a.year_max ?? null,
      p_max_price_cents: a.max_price_cents ?? null, p_body_style: a.body_style ?? null, p_condition: a.condition ?? null, p_limit: a.limit,
    }),
  },
  draft_message: {
    description: 'Write a message to the customer AS A DRAFT. It is never sent from here: a person approves it in SalesOS, where consent, quiet hours and the gates run again.',
    scope: 'drafts:write',
    input: z.object({ lead_id: uuid, body: z.string().trim().min(1).max(1000), channel: z.enum(['sms', 'whatsapp', 'email']).optional() }).strict(),
    fn: 'mcp_draft_message', args: (a: { lead_id: string; body: string; channel?: string }) => ({ p_lead_id: a.lead_id, p_body: a.body, p_channel: a.channel ?? null }),
  },
} as const;
export type CrmToolName = keyof typeof CRM_TOOLS;
export const CRM_TOOL_NAMES = Object.keys(CRM_TOOLS) as CrmToolName[];
/** search_inventory does not take a user id (inventory is dealer-wide). */
const NO_USER = new Set<CrmToolName>(['search_inventory']);

export type ToolCallResult = { ok: true; data: unknown } | { ok: false; code: 'forbidden' | 'not_found' | 'invalid' | 'unknown_tool' | 'internal'; message: string };

/** Map a Postgres error to a safe, stable code. Internal errors never echo SQL text. */
export function mapDbError(message: string): ToolCallResult & { ok: false } {
  const m = message.replace(/^[a-z_]+:\s(?=(forbidden|not_found|invalid))/i, '');
  if (/^forbidden/i.test(m)) return { ok: false, code: 'forbidden', message: m.slice(0, 200) };
  if (/^not_found/i.test(m)) return { ok: false, code: 'not_found', message: 'Not found (or not visible to you).' };
  if (/^invalid/i.test(m) || /lead stage|unknown stage|invalid stage/i.test(m)) return { ok: false, code: 'invalid', message: m.slice(0, 200) };
  return { ok: false, code: 'internal', message: 'Something went wrong; nothing was changed.' };
}

export function redactArgs(name: string, args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...args };
  if (typeof out.body === 'string') { out.body_len = (out.body as string).length; delete out.body; }
  if (name === 'find_leads' && typeof out.query === 'string') out.query = `${(out.query as string).slice(0, 1)}…`;
  return out;
}

export function toolsForRole(scopes: string[]): CrmToolName[] {
  return CRM_TOOL_NAMES.filter((n) => scopes.includes(CRM_TOOLS[n].scope));
}

export async function callCrmTool(p: Principal, name: string, rawArgs: unknown, deps: CrmToolDeps): Promise<ToolCallResult> {
  if (!(name in CRM_TOOLS)) return { ok: false, code: 'unknown_tool', message: `Unknown tool ${name}` };
  const t = CRM_TOOLS[name as CrmToolName];
  const argsObj = (rawArgs && typeof rawArgs === 'object' ? rawArgs : {}) as Record<string, unknown>;
  const leadId = typeof argsObj.lead_id === 'string' ? argsObj.lead_id : null;
  let result: ToolCallResult;
  if (!p.scopes.includes(t.scope)) {
    result = { ok: false, code: 'forbidden', message: `Your role (${p.role}) cannot use ${name}.` };
  } else {
    const parsed = t.input.safeParse(argsObj);
    if (!parsed.success) {
      result = { ok: false, code: 'invalid', message: parsed.error.issues.map((i) => `${i.path.join('.') || 'input'}: ${i.message}`).join('; ').slice(0, 300) };
    } else {
      try {
        const base: Record<string, unknown> = { p_dealer_id: p.dealerId, p_role: p.role };
        if (!NO_USER.has(name as CrmToolName)) base.p_user_id = p.userId;
        const data = await deps.rpc(t.fn, { ...base, ...(t.args as (a: unknown) => Record<string, unknown>)(parsed.data) });
        const refused = name === 'draft_message' && data && typeof data === 'object' && (data as { ok?: boolean }).ok === false;
        result = refused ? { ok: false, code: 'invalid', message: String((data as { message?: string }).message ?? 'refused') } : { ok: true, data };
      } catch (e) {
        result = mapDbError((e as Error).message);
      }
    }
  }
  const draftId = result.ok && result.data && typeof result.data === 'object' ? ((result.data as { draft_id?: string }).draft_id ?? null) : null;
  await deps.audit({ principal: p, tool: name, args: redactArgs(name, argsObj), resultCode: result.ok ? 'ok' : result.code, leadId, draftId });
  return result;
}
