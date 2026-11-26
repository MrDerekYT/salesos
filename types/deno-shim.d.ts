// Type-check-only shim for the Deno globals used by Edge Functions (not shipped).
declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (req: Request) => Response | Promise<Response>): unknown;
};
