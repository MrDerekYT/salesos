/**
 * unsubscribe: RFC 8058 one-click endpoint + a human page.
 *  - POST (mail client one-click with body "List-Unsubscribe=One-Click", or the page's button) => opt-out recorded.
 *  - GET shows a confirm button and changes nothing (link scanners prefetch GETs).
 * Tokens are random, stored as sha256, never expire; redeeming twice is a no-op.
 */
import type { Rpc } from '../_shared/crm-tools.ts';

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const page = (title: string, body: string, status = 200) =>
  new Response(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title></head>` +
    `<body style="font-family:system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem">${body}</body></html>`, { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } });

export async function handleUnsubscribe(req: Request, deps: { rpc: Rpc; now(): Date }): Promise<Response> {
  const url = new URL(req.url);
  const token = url.searchParams.get('t') ?? '';
  if (!/^[a-f0-9]{32,128}$/i.test(token)) return page('Link not valid', '<p>This unsubscribe link is not valid.</p>', 400);
  if (req.method === 'GET') {
    return page('Unsubscribe', `<h1>Unsubscribe from email?</h1><form method="post" action="?t=${esc(token)}"><input type="hidden" name="confirm" value="1">` +
      '<button type="submit" style="font-size:1rem;padding:.6rem 1.2rem">Unsubscribe</button></form>');
  }
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const body = await req.text();
  const method = /List-Unsubscribe=One-Click/i.test(body) ? 'one_click_post' : 'web_form';
  const r = await deps.rpc<{ ok: boolean; dealer_name?: string; already?: boolean }>('redeem_unsubscribe_token', { p_token: token, p_method: method, p_now: deps.now().toISOString() });
  if (!r?.ok) return page('Link not valid', '<p>This unsubscribe link is not valid.</p>', 404);
  if (method === 'one_click_post') return new Response('', { status: 200 });
  return page('Unsubscribed', `<h1>You're unsubscribed</h1><p>${esc(r.dealer_name ?? 'The dealership')} will not email you again.</p>`);
}
