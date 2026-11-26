/**
 * Customer facts the agent may record, with validation. The SQL function agent_record_fact() re-validates everything
 * (it is the source of truth); this module gives the model friendlier, earlier errors and is shared with the tool schema.
 */
export const FACT_KEYS = ['budget_max_cents', 'trade_in_vin', 'preferred_trim', 'purchase_timeframe', 'wants_financing'] as const;
export type FactKey = typeof FACT_KEYS[number];
export const TIMEFRAMES = ['now', 'within_30_days', 'within_90_days', 'later'] as const;
export const MIN_FACT_CONFIDENCE = 0.5;
export const BUDGET_MIN_CENTS = 100_000;          // $1,000
export const BUDGET_MAX_CENTS = 50_000_000;       // $500,000

const TRANSLIT: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8, J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9, S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9,
};
const WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

/** ISO 3779 / NHTSA check digit (position 9). I, O and Q never appear in a VIN. */
export function isValidVin(input: string): boolean {
  const v = input.trim().toUpperCase();
  if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(v)) return false;
  let total = 0;
  for (let i = 0; i < 17; i++) {
    const ch = v[i];
    total += (/\d/.test(ch) ? Number(ch) : TRANSLIT[ch]) * WEIGHTS[i];
  }
  const check = total % 11;
  return v[8] === (check === 10 ? 'X' : String(check));
}

export type FactValidation = { ok: true; value: string | number | boolean } | { ok: false; code: 'invalid_value' | 'invalid_vin' | 'invalid_key'; message: string };
export function validateFact(key: string, value: unknown): FactValidation {
  switch (key) {
    case 'budget_max_cents':
      if (typeof value !== 'number' || !Number.isInteger(value) || value < BUDGET_MIN_CENTS || value > BUDGET_MAX_CENTS) {
        return { ok: false, code: 'invalid_value', message: 'budget_max_cents must be a whole number of CENTS between 100000 ($1,000) and 50000000 ($500,000). $35,000 is 3500000.' };
      }
      return { ok: true, value };
    case 'trade_in_vin':
      if (typeof value !== 'string' || !isValidVin(value)) {
        return { ok: false, code: 'invalid_vin', message: 'That VIN failed validation (17 characters, no I/O/Q, check digit). Do not guess it: ask the customer to re-send it.' };
      }
      return { ok: true, value: value.trim().toUpperCase() };
    case 'preferred_trim': {
      const t = typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim() : '';
      if (t.length < 1 || t.length > 60) return { ok: false, code: 'invalid_value', message: 'preferred_trim must be 1-60 characters.' };
      return { ok: true, value: t };
    }
    case 'purchase_timeframe':
      if (typeof value !== 'string' || !(TIMEFRAMES as readonly string[]).includes(value)) {
        return { ok: false, code: 'invalid_value', message: `purchase_timeframe must be one of ${TIMEFRAMES.join(', ')}.` };
      }
      return { ok: true, value };
    case 'wants_financing':
      if (typeof value !== 'boolean') return { ok: false, code: 'invalid_value', message: 'wants_financing must be true or false.' };
      return { ok: true, value };
    default:
      return { ok: false, code: 'invalid_key', message: `Unsupported fact. Allowed: ${FACT_KEYS.join(', ')}.` };
  }
}
