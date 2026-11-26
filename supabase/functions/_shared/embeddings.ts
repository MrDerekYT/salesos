/**
 * Pluggable embeddings. The database is the source of truth for dimensions (vector(1536)); every provider must
 * return exactly EMBEDDING_DIM floats or the batch is rejected before anything is written.
 *
 * No provider configured => `providerFromEnv` returns null and the system runs FTS-only: match_kb() still answers
 * from the generated tsvector, and the embed worker defers its queue instead of failing it.
 */
export const EMBEDDING_DIM = 1536;

export interface EmbeddingProvider {
  /** Stored in kb_chunks.embedding_model; a change triggers requeue_embeddings_for_model(). */
  readonly model: string;
  embed(texts: string[], opts?: { signal?: AbortSignal }): Promise<number[][]>;
}

export class EmbeddingError extends Error {
  readonly retryable: boolean;
  constructor(message: string, retryable: boolean) { super(message); this.retryable = retryable; }
}

export function assertDims(vectors: number[][], expected: number, dim = EMBEDDING_DIM): number[][] {
  if (vectors.length !== expected) throw new EmbeddingError(`provider returned ${vectors.length} vectors for ${expected} inputs`, false);
  for (const v of vectors) {
    if (!Array.isArray(v) || v.length !== dim) throw new EmbeddingError(`embedding has ${Array.isArray(v) ? v.length : 'no'} dimensions, expected ${dim}`, false);
    if (v.some((x) => typeof x !== 'number' || !Number.isFinite(x))) throw new EmbeddingError('embedding contains a non-finite value', false);
  }
  return vectors;
}

/** pgvector text literal for RPC arguments ("[0.1,0.2,...]"). */
export const toPgVector = (v: number[]): string => `[${v.join(',')}]`;

type FetchLike = (url: string, init: RequestInit) => Promise<Response>;

/** Any OpenAI-compatible /embeddings endpoint (OpenAI, Azure OpenAI, Vercel AI Gateway, vLLM, Ollama with the compat API). */
export function openAiCompatibleProvider(o: { baseUrl: string; apiKey: string; model: string; dimensions?: number; fetch?: FetchLike; maxBatch?: number }): EmbeddingProvider {
  const f: FetchLike = o.fetch ?? ((u, i) => fetch(u, i));
  const maxBatch = o.maxBatch ?? 96;
  return {
    model: o.model,
    async embed(texts, opts) {
      const out: number[][] = [];
      for (let i = 0; i < texts.length; i += maxBatch) {
        const batch = texts.slice(i, i + maxBatch);
        let res: Response;
        try {
          res = await f(`${o.baseUrl.replace(/\/$/, '')}/embeddings`, {
            method: 'POST', signal: opts?.signal,
            headers: { 'content-type': 'application/json', authorization: `Bearer ${o.apiKey}` },
            body: JSON.stringify({ model: o.model, input: batch, ...(o.dimensions ? { dimensions: o.dimensions } : {}) }),
          });
        } catch (e) {
          throw new EmbeddingError(`embeddings request failed: ${(e as Error).message}`, true);
        }
        if (!res.ok) throw new EmbeddingError(`embeddings HTTP ${res.status}`, res.status === 429 || res.status >= 500);
        const json = await res.json() as { data?: { index: number; embedding: number[] }[] };
        const rows = [...(json.data ?? [])].sort((a, b) => a.index - b.index).map((d) => d.embedding);
        out.push(...assertDims(rows, batch.length));
      }
      return out;
    },
  };
}

/** EMBEDDINGS_BASE_URL + EMBEDDINGS_API_KEY + EMBEDDINGS_MODEL, or null (=> FTS-only mode). */
export function providerFromEnv(get: (k: string) => string | undefined, f?: FetchLike): EmbeddingProvider | null {
  const apiKey = get('EMBEDDINGS_API_KEY');
  if (!apiKey) return null;
  return openAiCompatibleProvider({
    baseUrl: get('EMBEDDINGS_BASE_URL') ?? 'https://api.openai.com/v1',
    apiKey, model: get('EMBEDDINGS_MODEL') ?? 'text-embedding-3-small', dimensions: EMBEDDING_DIM, fetch: f,
  });
}
