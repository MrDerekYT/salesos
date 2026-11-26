/**
 * Web Crypto helpers shared by the webhook verifiers (runs unchanged on Deno Edge and Node 24).
 * Constant-time comparison everywhere a signature is checked.
 */
const enc = new TextEncoder();

export function toBase64(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
export function fromBase64(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

export async function hmac(alg: 'SHA-1' | 'SHA-256', key: string | Uint8Array, data: string): Promise<Uint8Array> {
  const raw = typeof key === 'string' ? enc.encode(key) : key;
  const k = await crypto.subtle.importKey('raw', raw as BufferSource, { name: 'HMAC', hash: alg }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(data)));
}

export async function sha256Hex(data: string): Promise<string> {
  return toHex(new Uint8Array(await crypto.subtle.digest('SHA-256', enc.encode(data))));
}

/** Constant-time string compare (length leak only). */
export function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}
