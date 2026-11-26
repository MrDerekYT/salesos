/** Hourly pull of WhatsApp template status per WABA (push updates arrive on webhook-meta). Missing templates => DELETED. */
import type { Rpc } from '../_shared/crm-tools.ts';
import { fetchTemplates, type WhatsAppOptions } from '../_shared/channels/whatsapp.ts';

export async function syncTemplates(rpc: Rpc, o: WhatsAppOptions, now: Date): Promise<{ numbers: number; templates: number; errors: string[] }> {
  const nums = await rpc<{ number_id: string; waba_id: string }[]>('list_template_numbers', {});
  const out = { numbers: 0, templates: 0, errors: [] as string[] };
  for (const n of nums) {
    try {
      const rows = await fetchTemplates(o, n.waba_id);
      out.templates += await rpc<number>('upsert_message_templates', { p_number_id: n.number_id, p_templates: rows, p_now: now.toISOString() });
      out.numbers++;
    } catch (e) {
      out.errors.push(`${n.number_id}: ${(e as Error).message.slice(0, 160)}`);
    }
  }
  return out;
}
