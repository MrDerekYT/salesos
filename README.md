# Sales OS

**The Facebook-powered sales operating system that makes winning feel inevitable.**

Connect your Facebook Page and Ad Account. Watch leads flood in. Auto-optimize creatives. Kill losers. Scale winners. Close deals.

Built on the best patterns from open-source Meta Ads systems (meta-ads-system, meta-ads-growth-os, Atomic CRM, Dealflow CRM) and enhanced into a premium, conversion-focused experience.

## Why this feels like a guarantee

- **One-click Facebook connect** — OAuth into Pages + Lead Ads + Insights
- **Live pipeline** with visual win-rate and velocity
- **Meta Ads intelligence** — diagnostic rules, creative fatigue detection, auto-kill/scale suggestions
- **AI creative generator** hooks (ready for your LLM)
- **Supabase realtime** — everything updates instantly
- **Dark, high-end UI** designed to make you feel in control

## Stack

- Next.js 15 + React 19
- Supabase (Auth, Postgres, Realtime, Storage)
- Tailwind
- Vercel deploy ready

## Quick start

1. Clone and install
```bash
git clone https://github.com/MrDerekYT/salesos.git
cd salesos
npm install
```

2. Create a Supabase project and run the SQL in `supabase/schema.sql`

3. Copy `.env.example` to `.env.local` and fill keys

4. `npm run dev`

5. Deploy to Vercel — import the repo, add env vars, done.

## Facebook setup

Create a Meta App, add Facebook Login + Marketing API permissions (`pages_show_list`, `leads_retrieval`, `ads_read`, `ads_management`).

Redirect URI: `https://your-domain.com/api/auth/meta/callback`

## Best repos this enhances

- [meta-ads-system](https://github.com/luukalleman/meta-ads-system) — auto-kill losers, generate creatives
- [meta-ads-growth-os](https://github.com/EngAmi/meta-ads-growth-os) — diagnostic engine + OAuth
- [marmelab/atomic-crm](https://github.com/marmelab/atomic-crm) — Supabase CRM patterns
- [Mark1Anthony/dealflow-crm](https://github.com/Mark1Anthony/dealflow-crm) — Next.js + Supabase pipeline

Fork, enhance, own the pipeline.