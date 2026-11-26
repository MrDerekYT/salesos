/**
 * Inbound opt-out (STOP) detection for SMS/WhatsApp/email replies. Pure, dependency-free (runs in Deno or Node).
 *
 * Design (original; the *idea* of "intent, not word" comes from DeskcommCRM's opt-out module, MIT):
 *   1. A bare keyword (whole message) is an unambiguous command: STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT
 *      (CTIA / carrier standard set) plus REVOKE and OPT OUT (named as reasonable revocation means in the FCC's
 *      2024 TCPA revocation rule). HELP/INFO and START/UNSTOP are handled too.
 *   2. Phrases that pair a cessation verb with a *communication object* ("stop texting me", "remove me from your
 *      list") are unambiguous opt-outs.
 *   3. Ambiguous signals ("leave me alone", "wrong number", "not interested anymore", legal threats) NEVER write
 *      the revocation themselves. They silence the bot and escalate to a human, who confirms. This mirrors the
 *      "unambiguous writes the block; ambiguous only silences" policy, because a false positive silently loses a
 *      customer, while a false negative is a compliance risk the human review catches.
 *   4. Automotive negatives that must NOT trigger: "can I stop by at 3?", "cancel my appointment",
 *      "end of the month", "don't call me before 10am" (a time preference).
 * Not legal advice: have counsel review the keyword set, the 10-business-day clock and the confirmation text.
 */

export type OptOutLevel = 'none' | 'help' | 'start' | 'stop' | 'probable_stop';
export type OptOutAction = 'none' | 'send_help' | 'record_grant' | 'record_revoke' | 'silence_and_escalate';

export interface OptOutResult {
  level: OptOutLevel;
  action: OptOutAction;
  /** 'channel' = revoke this channel only (SMS STOP semantics); 'all_channels' = wording asked for all contact. */
  scope: 'channel' | 'all_channels';
  /** 0..1: how sure we are that this is a revocation (bare keyword = 1). */
  confidence: number;
  matched: string | null;
  reason: string;
  /** Extra signals for the human: e.g. legal_threat, appointment_cancel, contact_time_preference, calls_only. */
  hints: string[];
  legalThreat: boolean;
}

/** lower-case, strip accents/emoji/most punctuation at the edges, collapse whitespace. */
export function normalizeInbound(text: string): string {
  return text
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[\u2018\u2019\u02bc]/g, "'")
    .replace(/[\p{Extended_Pictographic}\u200d\ufe0f]/gu, ' ')
    .replace(/[^a-z0-9'\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export const STOP_KEYWORDS: ReadonlySet<string> = new Set([
  'stop', 'stopall', 'stop all', 'unsubscribe', 'cancel', 'end', 'quit', 'revoke', 'opt out', 'optout', 'opt-out',
  // Spanish (US dealerships)
  'parar', 'detener', 'baja', 'cancelar',
]);
export const START_KEYWORDS: ReadonlySet<string> = new Set(['start', 'unstop', 'subscribe']); // NOT "yes": it answers questions
export const HELP_KEYWORDS: ReadonlySet<string> = new Set(['help', 'info']);

const COMM_OBJECT =
  '(?:text(?:s|ing)?|messag(?:e|es|ing)|contact(?:ing)?|call(?:s|ing)?|email(?:s|ing)?|send(?:ing)?|notification(?:s)?|alert(?:s)?|reach(?:ing)?|communicat(?:e|ion|ions|ing)|mensajes|textos)';

const UNAMBIGUOUS_PATTERNS: { id: string; re: RegExp; allChannels?: boolean }[] = [
  { id: 'stop_object', re: new RegExp(`\\b(?:stop|quit|cease|end|halt)\\s+(?:all\\s+|the\\s+|any\\s+|these\\s+)*${COMM_OBJECT}\\b`) },
  { id: 'stop_all_contact', re: /\b(?:stop|end|cease)\s+all\s+(?:contact|communications?)\b/, allChannels: true },
  { id: 'no_more', re: new RegExp(`\\bno\\s+more\\s+${COMM_OBJECT}\\b`) },
  { id: 'dont_contact_me', re: new RegExp(`\\b(?:don'?t|do\\s+not|dont|never)\\s+(?:ever\\s+)?(?:text|message|contact|call|email|send|reach)\\s+(?:me|us)\\b`) },
  { id: 'do_not_contact', re: /\bdo\s+not\s+contact\b/, allChannels: true },
  { id: 'remove_me', re: /\b(?:remove|delete|take|drop|put)\b.{0,25}\b(?:me|my\s+(?:number|phone|name|email|info|information))\b.{0,30}\b(?:list|lists|database|texts?|messaging|contacts?|records?|system|off)\b/ },
  { id: 'take_me_off', re: /\btake\s+(?:me|my\s+(?:number|name|email))\s+off\b/ },
  { id: 'unsubscribe', re: /\bunsubscribe(?:\s+me)?\b/ },
  { id: 'opt_out', re: /\bopt(?:ing)?[\s-]*(?:me\s+)?out\b/ },
  { id: 'please_stop', re: /^(?:please\s+)?stop(?:\s+(?:it|this|now|please|already|messaging|texting))?$/ },
  { id: 'es_no_mas', re: /\bno\s+(?:me\s+)?(?:envien|manden|escriban|llamen)\s+(?:mas\s+)?(?:mensajes|textos)\b/ },
];

const PROBABLE_PATTERNS: { id: string; re: RegExp }[] = [
  { id: 'leave_me_alone', re: /\b(?:leave\s+me\s+alone|go\s+away|knock\s+it\s+off|back\s+off)\b/ },
  { id: 'not_interested', re: /\b(?:not\s+interested(?:\s+any\s*more)?|no\s+longer\s+interested|lose\s+my\s+number)\b/ },
  { id: 'wrong_number', re: /\bwrong\s+(?:number|person)\b|\bnot\s+(?:the\s+)?(?:right\s+)?person\b/ },
  { id: 'enough', re: /^(?:enough|i'?m\s+done|that'?s\s+enough|stop\s+it\s+now)$/ },
  { id: 'never_consented', re: /\b(?:never|did(?:n'?t|\s+not)|do(?:n'?t|\s+not))\s+(?:sign(?:ed)?\s+up|opt(?:ed)?\s+in|subscribe[d]?|agree[d]?|(?:give|gave)\s+(?:you\s+)?(?:my\s+)?(?:number|permission|consent))\b/ },
  { id: 'harassment', re: /\b(?:harass(?:ing|ment)?|spam(?:ming)?|stalk(?:ing)?)\b/ },
  { id: 'calls_only', re: /\b(?:don'?t|do\s+not|stop)\s+call(?:ing)?(?:\s+me)?\b(?!.*\b(?:text|message|email)\b)/ },
];

const LEGAL_RE = /\b(?:lawyer|attorney|sue|suing|lawsuit|tcpa|fcc|attorney\s+general|cease\s+and\s+desist|report(?:ing)?\s+you|class\s+action)\b/;

// Things that look like opt-outs but are ordinary dealership conversation.
const NEGATIVE_GUARDS: { id: string; re: RegExp; hint: string }[] = [
  { id: 'stop_by', re: /\bstop(?:ping)?\s+(?:by|in|over|off|at)\b/, hint: 'visit_intent' },
  { id: 'cancel_thing', re: /\bcancel(?:l?ing)?\s+(?:my|the|our|an?|this|that)\s+(?:appointment|test\s*drive|visit|reservation|order|deposit|service|trade|lease|loan|application|credit|check|hold)\b/, hint: 'appointment_cancel' },
  { id: 'end_of', re: /\bend\s+of\s+(?:the\s+)?(?:month|week|day|year|quarter)\b/, hint: 'timing_phrase' },
  { id: 'quit_other', re: /\bquit\s+(?:my\s+job|smoking)\b/, hint: 'unrelated' },
];
// "don't text me after 9pm" is a contact-time preference, not a revocation.
const TIME_PREF_RE = /\b(?:don'?t|do\s+not|never)\s+(?:text|call|message|contact|email)\s+(?:me\s+)?(?:before|after|until|between|during|on\s+(?:weekends|sundays|saturdays)|at\s+(?:night|work)|early|late)\b/;
const CHANNEL_PREF_RE = /\b(?:don'?t|do\s+not)\s+call(?:\s+me)?\s*,?\s*(?:just\s+|only\s+|please\s+)?(?:text|message)\b/;

const NONE: OptOutResult = {
  level: 'none', action: 'none', scope: 'channel', confidence: 0, matched: null, reason: 'no opt-out signal', hints: [], legalThreat: false,
};

export function classifyInbound(text: string | null | undefined): OptOutResult {
  if (!text || !text.trim()) return { ...NONE, hints: [] };
  const n = normalizeInbound(text);
  if (!n) return { ...NONE, hints: [] };
  const legalThreat = LEGAL_RE.test(n);
  const hints: string[] = legalThreat ? ['legal_threat'] : [];

  // 1) whole-message keywords
  if (STOP_KEYWORDS.has(n)) {
    return { level: 'stop', action: 'record_revoke', scope: 'channel', confidence: 1, matched: n, reason: `keyword "${n}"`, hints, legalThreat };
  }
  if (START_KEYWORDS.has(n)) {
    return { level: 'start', action: 'record_grant', scope: 'channel', confidence: 1, matched: n, reason: `keyword "${n}"`, hints, legalThreat };
  }
  if (HELP_KEYWORDS.has(n)) {
    return { level: 'help', action: 'send_help', scope: 'channel', confidence: 1, matched: n, reason: `keyword "${n}"`, hints, legalThreat };
  }

  // guards that explain why a phrase is NOT an opt-out
  const preference = TIME_PREF_RE.test(n);
  if (preference) hints.push('contact_time_preference');
  if (CHANNEL_PREF_RE.test(n)) hints.push('prefers_text_over_calls');
  const guarded = NEGATIVE_GUARDS.filter((g) => g.re.test(n));
  for (const g of guarded) hints.push(g.hint);

  // 2) unambiguous phrases (skipping the one rule a time preference overlaps)
  for (const p of UNAMBIGUOUS_PATTERNS) {
    if (preference && p.id === 'dont_contact_me') continue;
    if (CHANNEL_PREF_RE.test(n) && p.id === 'dont_contact_me') continue;
    const m = n.match(p.re);
    if (m) {
      return {
        level: 'stop', action: 'record_revoke', scope: p.allChannels ? 'all_channels' : 'channel', confidence: 0.95,
        matched: m[0], reason: `phrase:${p.id}`, hints, legalThreat,
      };
    }
  }

  // 3) legal threat or ambiguous signals => silence + human
  if (legalThreat) {
    return { level: 'probable_stop', action: 'silence_and_escalate', scope: 'channel', confidence: 0.8, matched: n.match(LEGAL_RE)![0], reason: 'legal threat', hints, legalThreat };
  }
  if (guarded.length === 0) {
    for (const p of PROBABLE_PATTERNS) {
      const m = n.match(p.re);
      if (m) {
        if (p.id === 'calls_only') hints.push('calls_only');
        return { level: 'probable_stop', action: 'silence_and_escalate', scope: 'channel', confidence: 0.6, matched: m[0], reason: `ambiguous:${p.id}`, hints, legalThreat };
      }
    }
  }
  return { ...NONE, hints, legalThreat };
}

/**
 * Should the agent be allowed to keep talking after this inbound? Used by the before-send opt-out gate.
 * Anything stop-like (certain or probable) blocks automation; only a human can proceed on a probable stop.
 */
export function blocksAutomation(r: OptOutResult): boolean {
  return r.level === 'stop' || r.level === 'probable_stop';
}

/** The ONE confirmation message TCPA practice allows after STOP. Must not contain marketing. */
export function stopConfirmationText(dealerName: string): string {
  return `${dealerName}: You're unsubscribed and will receive no more messages. Reply START to resubscribe.`;
}
export function helpText(dealerName: string, phone?: string): string {
  return `${dealerName}: Reply STOP to opt out.${phone ? ` Questions? Call ${phone}.` : ''} Msg & data rates may apply.`;
}
