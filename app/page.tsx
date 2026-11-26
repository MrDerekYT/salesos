'use client'

import { useState } from 'react'
import { Facebook, Sparkles, Car, Users, MessageSquare, Target, Zap } from 'lucide-react'

const NAV = [
  { href: '#', label: 'Home', icon: Sparkles },
  { href: '#', label: 'Inbox', icon: MessageSquare },
  { href: '#', label: 'Inventory', icon: Car },
  { href: '#', label: 'Customers', icon: Users },
  { href: '#', label: 'AI', icon: Zap },
]

export default function Home() {
  const [autopilot, setAutopilot] = useState(true)

  return (
    <div className="min-h-screen lg:pl-[248px]">
      {/* Sidebar */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-[248px] flex-col border-r border-white/[0.05] bg-ink-950/70 backdrop-blur-2xl lg:flex">
        <div className="px-5 pb-4 pt-5">
          <div className="flex items-center gap-2.5">
            <div className="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-brand-500 to-violet-500 text-sm font-bold">S</div>
            <span className="text-lg font-semibold tracking-tight">Sales OS</span>
          </div>
        </div>
        <nav className="flex-1 space-y-0.5 px-3">
          {NAV.map((item) => (
            <a key={item.label} href={item.href} className="flex items-center gap-3 rounded-xl px-3 py-2 text-[14px] font-medium text-ink-400 transition hover:bg-white/[0.04] hover:text-white">
              <item.icon className="h-4 w-4" />
              {item.label}
            </a>
          ))}
        </nav>
        <div className="p-3">
          <button
            onClick={() => setAutopilot(!autopilot)}
            className={`flex w-full items-center gap-2 rounded-xl border px-3 py-2.5 text-xs font-semibold transition ${
              autopilot ? 'border-signal-400/20 bg-signal-400/[0.07] text-signal-400' : 'border-white/[0.08] bg-white/[0.03] text-ink-400'
            }`}
          >
            <span className={`h-2 w-2 rounded-full ${autopilot ? 'bg-signal-400 animate-pulse' : 'bg-ink-500'}`} />
            Autopilot {autopilot ? 'on' : 'off'}
          </button>
        </div>
      </aside>

      <main className="mx-auto max-w-[1280px] px-4 py-8 sm:px-6 lg:px-10">
        <div className="mb-8">
          <div className="label mb-2">Today</div>
          <h1 className="text-4xl font-semibold tracking-tight text-white">Good evening, Derek</h1>
          <p className="mt-2 text-ink-400">Sales OS is working for you. Marketplace Assist fills listings. AI drafts follow-ups. You close.</p>
        </div>

        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
          {[
            { label: 'Active Inventory', value: '24', icon: Car },
            { label: 'Open Leads', value: '18', icon: Target },
            { label: 'Replies Waiting', value: '5', icon: MessageSquare },
            { label: 'Win Rate', value: '87%', icon: Zap },
          ].map((s) => (
            <div key={s.label} className="surface p-5">
              <s.icon className="h-5 w-5 text-brand-400 mb-3" />
              <div className="text-3xl font-semibold tracking-tight">{s.value}</div>
              <div className="text-sm text-ink-400 mt-1">{s.label}</div>
            </div>
          ))}
        </div>

        <div className="surface p-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="font-medium">Marketplace Assist</h2>
            <span className="text-xs text-signal-400">Extension ready</span>
          </div>
          <p className="text-sm text-ink-300 max-w-xl">
            Open Facebook Marketplace → Create listing → click “Fill from Sales OS”. The extension fills year, make, model, price, mileage, description, and photos from your inventory. You review and publish.
          </p>
          <div className="mt-4 flex gap-3">
            <button className="btn-primary">
              <Facebook className="h-4 w-4" /> Connect Marketplace
            </button>
            <button className="rounded-xl border border-white/10 bg-white/[0.04] px-4 py-2.5 text-sm font-semibold text-ink-100">
              Install Extension
            </button>
          </div>
        </div>
      </main>
    </div>
  )
}