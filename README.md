# Sales OS

High-end Facebook Marketplace sales operating system.

Built from the same foundation as the private `facebook-marketplace` project: premium dark UI, inventory + CRM, AI autopilot, and the Marketplace Assist browser extension that fills listings from your inventory in one click.

## What makes it the best

- **Marketplace Assist extension** — content script that fills Facebook Marketplace (and OfferUp) vehicle listing forms from your Sales OS inventory. Year, make, model, price, mileage, colors, description, photos. You review and publish.
- **Premium dark shell** — Inter typography, ink-950 background, surface cards, autopilot pill, command palette patterns.
- **Inventory → Listing → Lead loop** — the core sales motion for Marketplace sellers.
- **AI autopilot** patterns for follow-ups and next actions.

## Stack

Next.js 16 · Tailwind v4 · React 19

## Run

```bash
npm install
npm run dev
```

The full production system (auth, Postgres, full CRM, calling, appointments) lives in the private `facebook-marketplace` repo. This public repo is the polished, high-quality public face and starting point.