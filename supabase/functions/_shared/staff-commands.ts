/**
 * CRM by text (feature 7). A message to the store number from an ALLOW-LISTED staff identity (resolve_staff_sender:
 * active + verified + current member; never admin) is a command, not a customer message. Anything else returns null
 * and continues down the customer pipeline. Commands reuse the MCP tool layer, so scopes, visibility, drafts-only and
 * auditing are identical. Replies stay short enough for one or two SMS segments.
 *
 *   who needs attention            -> list_attention
 *   lead sarah lopez               -> get_lead (name resolved via find_leads; ambiguity => ask)
 *   move sarah to negotiating      -> move_stage (+ "undo" hint)
 *   task sarah: call about trade tomorrow   -> create_task (today | tomorrow | in N hours/days; default tomorrow)
 *   find 2022 tacoma under 35k     -> search_inventory
 *   draft to sarah: <text>         -> draft_message (saved for approval, never sent)
 */
import { callCrmTool, type CrmToolDeps, type Principal, type ToolCallResult } from './crm-tools.ts';
import type { Channel } from './before-send.ts';

export type StaffCommand =
  | { kind: 'attention' }
  | { kind: 'lead'; who: string }
  | { kind: 'move'; who: string; stage: string }
  | { kind: 'task'; who: string; title: string; due: { hours: number } }
  | { kind: 'find'; filters: { make?: string; model?: string; year_min?: number; year_max?: number; max_price_cents?: number; condition?: 'new' | 'used' | 'cpo' } }
  | { kind: 'draft'; who: string; body: string }
  | { kind: 'help' };

const STAGE_ALIASES: Record<string, string> = {
  new: 'new', contacted: 'contacted', qualifying: 'qualifying', qualified: 'qualified', 'test drive': 'test_drive', test_drive: 'test_drive', testdrive: 'test_drive',
  negotiating: 'negotiating', negotiation: 'negotiating', won: 'won', sold: 'won', lost: 'lost', dead: 'lost',
};
const MAKES = ['acura', 'audi', 'bmw', 'buick', 'cadillac', 'chevrolet', 'chevy', 'chrysler', 'dodge', 'ford', 'gmc', 'honda', 'hyundai', 'infiniti', 'jeep', 'kia', 'lexus', 'lincoln', 'mazda', 'mercedes', 'mitsubishi', 'nissan', 'ram', 'subaru', 'tesla', 'toyota', 'volkswagen', 'vw', 'volvo'];
const MAKE_CANON: Record<string, string> = { chevy: 'chevrolet', vw: 'volkswagen' };

export function parseDue(text: string): { title: string; hours: number } {
  const t = text.trim();
  let m = /\s+(today|tonight)$/i.exec(t); if (m) return { title: t.slice(0, m.index).trim(), hours: 3 };
  m = /\s+tomorrow$/i.exec(t); if (m) return { title: t.slice(0, m.index).trim(), hours: 24 };
  m = /\s+in\s+(\d{1,3})\s*(h|hr|hrs|hours?|d|days?)$/i.exec(t);
  if (m) return { title: t.slice(0, m.index).trim(), hours: Number(m[1]) * (/^d/i.test(m[2]) ? 24 : 1) };
  return { title: t, hours: 24 };
}

export function parseMoneyCents(s: string): number | null {
  const m = /^\$?\s*(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(k)?$/i.exec(s.trim());
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, '')) * (m[2] ? 1000 : 1);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : null;
}

export function parseInventoryQuery(q: string): StaffCommand & { kind: 'find' } {
  const filters: (StaffCommand & { kind: 'find' })['filters'] = {};
  let rest = ` ${q.toLowerCase()} `;
  const price = /\s(?:under|below|less than|max|<)\s*(\$?[\d,.]+k?)\s/.exec(rest);
  if (price) { const c = parseMoneyCents(price[1]); if (c) filters.max_price_cents = c; rest = rest.replace(price[0], ' '); }
  const years = /\s((?:19|20)\d{2})(?:\s*(?:-|to)\s*((?:19|20)\d{2}))?\s/.exec(rest);
  if (years) { filters.year_min = Number(years[1]); filters.year_max = Number(years[2] ?? years[1]); rest = rest.replace(years[0], ' '); }
  const cond = /\s(new|used|cpo|certified)\s/.exec(rest);
  if (cond) { filters.condition = cond[1] === 'certified' ? 'cpo' : (cond[1] as 'new' | 'used' | 'cpo'); rest = rest.replace(cond[0], ' '); }
  const words = rest.trim().split(/\s+/).filter(Boolean);
  const mi = words.findIndex((w) => MAKES.includes(w));
  if (mi >= 0) { filters.make = MAKE_CANON[words[mi]] ?? words[mi]; words.splice(mi, 1); }
  const model = words.filter((w) => !['a', 'an', 'the', 'any', 'me', 'for'].includes(w)).join(' ');
  if (model) filters.model = model;
  return { kind: 'find', filters };
}

export function parseStaffCommand(raw: string): StaffCommand {
  const t = raw.trim().replace(/\s+/g, ' ');
  if (/^(?:who|what)(?:'s| is)? (?:needs|need) (?:my )?attention\??$|^(?:attention|today|hot list|list)\??$/i.test(t)) return { kind: 'attention' };
  let m = /^move (.+?) to (.+?)\.?$/i.exec(t);
  if (m) { const stage = STAGE_ALIASES[m[2].toLowerCase()]; return stage ? { kind: 'move', who: m[1], stage } : { kind: 'help' }; }
  m = /^(?:task|remind me)(?: for| to)? (.+?):\s*(.+)$/i.exec(t);
  if (m) { const d = parseDue(m[2]); return { kind: 'task', who: m[1], title: d.title, due: { hours: d.hours } }; }
  m = /^(?:find|search|inventory) (.+)$/i.exec(t);
  if (m) return parseInventoryQuery(m[1]);
  m = /^draft(?: to| for)? (.+?):\s*([\s\S]+)$/i.exec(raw.trim());
  if (m) return { kind: 'draft', who: m[1].trim(), body: m[2].trim() };
  m = /^(?:lead|show|info) (.+)$/i.exec(t);
  if (m) return { kind: 'lead', who: m[1] };
  return { kind: 'help' };
}

export const HELP_TEXT = 'Commands: "who needs attention" | "lead <name>" | "move <name> to <stage>" | "task <name>: <what> tomorrow" | "find 2022 tacoma under 35k" | "draft to <name>: <text>"';

export interface StaffDeps extends CrmToolDeps {
  resolveSender(dealerId: string, channel: Channel, address: string): Promise<{ staff_identity_id: string; user_id: string; role: 'viewer' | 'sales' | 'manager'; scopes: string[] } | null>;
  now(): Date;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const usd = (c: number | null | undefined) => (c == null ? 'price n/a' : `$${Math.round(c / 100).toLocaleString('en-US')}`);
const fail = (r: ToolCallResult & { ok: false }) => (r.code === 'forbidden' ? `Not allowed: ${r.message}` : r.code === 'not_found' ? 'No such lead (or not yours).' : `Couldn't do that: ${r.message}`);

async function resolveLead(p: Principal, who: string, deps: StaffDeps): Promise<{ id: string; name: string } | string> {
  if (UUID_RE.test(who)) return { id: who, name: 'lead' };
  const r = await callCrmTool(p, 'find_leads', { query: who, limit: 5 }, deps);
  if (!r.ok) return fail(r);
  const rows = r.data as { lead_id: string; name: string; stage: string }[];
  if (rows.length === 0) return `No lead matches "${who}".`;
  const exact = rows.filter((x) => x.name.toLowerCase() === who.toLowerCase());
  if (rows.length === 1 || exact.length === 1) { const x = exact[0] ?? rows[0]; return { id: x.lead_id, name: x.name }; }
  return `Which one? ${rows.slice(0, 4).map((x, i) => `${i + 1}) ${x.name} (${x.stage})`).join(' ')}. Reply with the full name.`;
}

/** Returns the reply to text back, or null when the sender is not an allow-listed staff member (=> customer pipeline). */
export async function handleStaffText(a: { dealerId: string; channel: Channel; address: string; text: string }, deps: StaffDeps): Promise<string | null> {
  const who = await deps.resolveSender(a.dealerId, a.channel, a.address);
  if (!who) return null;
  const p: Principal = { dealerId: a.dealerId, userId: who.user_id, role: who.role, scopes: who.scopes, actorKind: `staff_${a.channel}` as Principal['actorKind'], staffIdentityId: who.staff_identity_id };
  const cmd = parseStaffCommand(a.text);
  switch (cmd.kind) {
    case 'help': return HELP_TEXT;
    case 'attention': {
      const r = await callCrmTool(p, 'list_attention', { limit: 5 }, deps);
      if (!r.ok) return fail(r);
      const rows = r.data as { name: string; reason: string }[];
      return rows.length ? rows.map((x, i) => `${i + 1}) ${x.name}: ${x.reason}`).join('\n').slice(0, 600) : 'Nothing needs you right now.';
    }
    case 'lead': {
      const l = await resolveLead(p, cmd.who, deps); if (typeof l === 'string') return l;
      const r = await callCrmTool(p, 'get_lead', { lead_id: l.id }, deps);
      if (!r.ok) return fail(r);
      const j = r.data as { lead: { stage: string }; contact: { name: string }; vehicle: { year: number; make: string; model: string } | null; recent_messages: { direction: string; body: string }[] };
      const last = j.recent_messages[0];
      return `${j.contact.name} | ${j.lead.stage}${j.vehicle ? ` | ${j.vehicle.year} ${j.vehicle.make} ${j.vehicle.model}` : ''}${last ? ` | last ${last.direction}: "${last.body.slice(0, 120)}"` : ''}`;
    }
    case 'move': {
      const l = await resolveLead(p, cmd.who, deps); if (typeof l === 'string') return l;
      const r = await callCrmTool(p, 'move_stage', { lead_id: l.id, stage: cmd.stage, reason: `by text: ${a.text.slice(0, 200)}` }, deps);
      if (!r.ok) return fail(r);
      const d = r.data as { decision: string; from: string; to: string };
      return d.decision === 'applied' ? `Moved ${l.name}: ${d.from} -> ${d.to}. Undo in SalesOS from the lead timeline.` : `${l.name} unchanged (${d.decision}).`;
    }
    case 'task': {
      const l = await resolveLead(p, cmd.who, deps); if (typeof l === 'string') return l;
      const due = new Date(deps.now().getTime() + cmd.due.hours * 3_600_000).toISOString();
      const r = await callCrmTool(p, 'create_task', { lead_id: l.id, title: cmd.title, due_at: due }, deps);
      return r.ok ? `Task added for ${l.name}: "${cmd.title}".` : fail(r);
    }
    case 'find': {
      const r = await callCrmTool(p, 'search_inventory', { ...cmd.filters, limit: 3 }, deps);
      if (!r.ok) return fail(r);
      const rows = r.data as { vin: string; year: number; make: string; model: string; trim: string | null; price_cents: number | null }[];
      return rows.length ? rows.map((v) => `${v.year} ${v.make} ${v.model}${v.trim ? ' ' + v.trim : ''} ${usd(v.price_cents)} (…${v.vin.slice(-6)})`).join('\n') : 'No matching units in stock.';
    }
    case 'draft': {
      const l = await resolveLead(p, cmd.who, deps); if (typeof l === 'string') return l;
      const r = await callCrmTool(p, 'draft_message', { lead_id: l.id, body: cmd.body }, deps);
      return r.ok ? `Draft saved for ${l.name}. Approve it in SalesOS to send (nothing was sent).` : fail(r);
    }
  }
}
