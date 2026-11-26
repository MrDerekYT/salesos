'use client'

import { useState } from 'react'
import { Facebook, Home, Columns, DollarSign, BarChart3, Zap, Plug, Settings, Bell, ChevronDown, Sparkles } from 'lucide-react'

const NAV = [
  { label: 'Overview', icon: Home, active: true },
  { label: 'Pipeline', icon: Columns },
  { label: 'Deals', icon: DollarSign },
  { label: 'Analytics', icon: BarChart3 },
  { label: 'Signals', icon: Zap },
  { label: 'Integrations', icon: Plug },
  { label: 'Settings', icon: Settings },
]

const PIPELINE = [
  {
    stage: 'Lead In',
    count: 32,
    more: 29,
    deals: [
      { name: 'BrightWave.io', person: 'Maya Chen', value: '$28,000', days: '2d', color: 'bg-blue-500' },
      { name: 'CloudCove', person: 'Jordan Pace', value: '$15,750', days: '1d', color: 'bg-sky-500' },
      { name: 'Northbeam', person: 'Taylor Reid', value: '$9,500', days: '3d', color: 'bg-indigo-500' },
    ],
  },
  {
    stage: 'Qualified',
    count: 28,
    more: 25,
    deals: [
      { name: 'SummitPath', person: 'Riley Adams', value: '$34,200', days: '4d', color: 'bg-violet-500' },
      { name: 'Velora Health', person: 'Casey Quinn', value: '$22,000', days: '2d', color: 'bg-purple-500' },
      { name: 'LumenShift', person: 'Drew Ellison', value: '$17,800', days: '3d', color: 'bg-fuchsia-500' },
    ],
  },
  {
    stage: 'Proposal',
    count: 12,
    more: 15,
    deals: [
      { name: 'Apexial', person: 'Morgan Blake', value: '$56,000', days: '5d', color: 'bg-violet-600' },
      { name: 'TrueNorth Co.', person: 'Parker Lane', value: '$31,500', days: '3d', color: 'bg-slate-500' },
      { name: 'ElevateNow', person: 'Sydney Cole', value: '$18,900', days: '2d', color: 'bg-cyan-600' },
    ],
  },
  {
    stage: 'Negotiation',
    count: 12,
    more: 9,
    deals: [
      { name: 'Meridian Works', person: 'Avery Shaw', value: '$68,000', days: '6d', color: 'bg-indigo-600' },
      { name: 'Clarity Labs', person: 'Robin Tate', value: '$44,000', days: '4d', color: 'bg-violet-500' },
      { name: 'NextStep AI', person: 'Cameron Ellis', value: '$29,500', days: '5d', color: 'bg-purple-600' },
    ],
  },
  {
    stage: 'Closed Won',
    count: 8,
    more: 5,
    deals: [
      { name: 'PulseGrid', person: 'Dakota Reid', value: '$75,000', days: '', color: 'bg-emerald-500' },
      { name: 'Bloomly', person: 'Emerson Vale', value: '$52,000', days: '', color: 'bg-emerald-500' },
      { name: 'HarborStack', person: 'Finley Moss', value: '$36,000', days: '', color: 'bg-emerald-600' },
    ],
  },
]

export default function Home() {
  const [connected] = useState(true)

  return (
    <div className="min-h-screen bg-[#050507] text-white">
      {/* Sidebar */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-[220px] flex-col border-r border-white/[0.05] bg-[#07080a]/80 backdrop-blur-2xl lg:flex">
        <div className="px-5 pt-6 pb-4">
          <div className="flex items-center gap-2.5">
            <div className="grid h-8 w-8 place-items-center rounded-lg bg-gradient-to-br from-blue-500 to-violet-600 text-sm font-bold">S</div>
            <span className="text-[17px] font-semibold tracking-tight">Sales OS</span>
          </div>
        </div>

        <nav className="flex-1 space-y-0.5 px-3">
          {NAV.map((item) => (
            <button
              key={item.label}
              className={`flex w-full items-center gap-3 rounded-xl px-3 py-2 text-[13.5px] font-medium transition ${
                item.active
                  ? 'bg-blue-500/10 text-white'
                  : 'text-gray-400 hover:bg-white/[0.04] hover:text-white'
              }`}
            >
              <item.icon className={`h-[16px] w-[16px] ${item.active ? 'text-blue-400' : ''}`} />
              {item.label}
            </button>
          ))}
        </nav>

        <div className="space-y-2 p-3">
          <div className="flex items-center gap-2.5 rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2.5">
            <div className="grid h-7 w-7 place-items-center rounded-full bg-blue-600">
              <Facebook className="h-3.5 w-3.5" />
            </div>
            <div className="min-w-0 flex-1">
              <div className="text-[12px] font-medium">Facebook Ads</div>
              <div className="flex items-center gap-1 text-[10px] text-emerald-400">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" /> Connected
              </div>
            </div>
            <ChevronDown className="h-3.5 w-3.5 text-gray-500" />
          </div>

          <div className="flex items-center gap-2.5 rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2.5">
            <div className="h-7 w-7 rounded-full bg-gradient-to-br from-violet-500 to-blue-500" />
            <div className="min-w-0 flex-1">
              <div className="truncate text-[12px] font-medium">Acme Growth</div>
              <div className="text-[10px] text-blue-400">Pro Plan</div>
            </div>
            <ChevronDown className="h-3.5 w-3.5 text-gray-500" />
          </div>
        </div>
      </aside>

      {/* Main */}
      <main className="lg:pl-[220px]">
        <div className="mx-auto max-w-[1400px] px-6 py-6">
          {/* Top bar */}
          <div className="mb-6 flex items-start justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Good evening, Alex.</h1>
              <p className="mt-1 text-sm text-gray-400">Here's what's happening with your pipeline today.</p>
            </div>
            <div className="flex items-center gap-2">
              <button className="flex items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3.5 py-2 text-xs text-gray-300">
                May 12 – May 18, 2024 <ChevronDown className="h-3.5 w-3.5" />
              </button>
              <button className="relative grid h-9 w-9 place-items-center rounded-xl border border-white/[0.08] bg-white/[0.03]">
                <Bell className="h-4 w-4" />
                <span className="absolute right-1.5 top-1.5 h-1.5 w-1.5 rounded-full bg-blue-500" />
              </button>
            </div>
          </div>

          {/* Top metrics */}
          <div className="mb-5 grid gap-4 lg:grid-cols-5">
            <div className="lg:col-span-3 rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
              <div className="flex items-start justify-between">
                <div>
                  <div className="text-xs text-gray-400">Win Rate</div>
                  <div className="mt-1 flex items-end gap-3">
                    <div className="text-6xl font-bold tracking-tighter">87%</div>
                    <div className="mb-2 flex items-center gap-1 text-sm text-emerald-400">
                      <span>↑</span> 12% <span className="text-gray-500">vs. May 5 – May 11</span>
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-2 rounded-xl border border-white/[0.08] bg-white/[0.03] px-3 py-2 text-xs">
                  <Facebook className="h-3.5 w-3.5 text-blue-400" />
                  Facebook Ads
                  <span className="ml-1 h-1.5 w-1.5 rounded-full bg-emerald-400" />
                </div>
              </div>
              {/* Fake sparkline */}
              <div className="mt-4 h-10 w-full">
                <svg viewBox="0 0 200 40" className="h-full w-full" preserveAspectRatio="none">
                  <path d="M0 30 C20 28, 40 22, 60 20 S100 12, 120 14 S160 8, 200 6" fill="none" stroke="#3b82f6" strokeWidth="2" />
                </svg>
              </div>
            </div>

            <div className="lg:col-span-2 rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
              <div className="text-xs text-gray-400">Pipeline Health</div>
              <div className="mt-4 flex items-center gap-6">
                <div className="relative grid h-20 w-20 place-items-center">
                  <svg className="absolute inset-0" viewBox="0 0 80 80">
                    <circle cx="40" cy="40" r="32" fill="none" stroke="#1e293b" strokeWidth="6" />
                    <circle cx="40" cy="40" r="32" fill="none" stroke="#3b82f6" strokeWidth="6" strokeDasharray="140" strokeDashoffset="40" strokeLinecap="round" transform="rotate(-90 40 40)" />
                  </svg>
                  <div className="text-center">
                    <div className="text-xl font-semibold">72</div>
                    <div className="text-[10px] text-gray-500">/100</div>
                  </div>
                </div>
                <div className="flex-1 space-y-2 text-sm">
                  <div className="flex justify-between"><span className="text-gray-400">Active Deals</span><span>128 <span className="text-emerald-400 text-xs">↑ 8%</span></span></div>
                  <div className="flex justify-between"><span className="text-gray-400">Avg. Deal Size</span><span>$42,750 <span className="text-emerald-400 text-xs">↑ 14%</span></span></div>
                  <div className="flex justify-between"><span className="text-gray-400">Time to Close</span><span>23 days <span className="text-rose-400 text-xs">↓ 6%</span></span></div>
                </div>
              </div>
            </div>
          </div>

          {/* Pipeline */}
          <div className="mb-5 rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
            <div className="mb-4 text-sm font-medium">Pipeline</div>
            <div className="grid grid-cols-5 gap-3">
              {PIPELINE.map((col) => (
                <div key={col.stage}>
                  <div className="mb-2 flex items-center justify-between text-xs">
                    <span className="text-gray-300">{col.stage}</span>
                    <span className="rounded-md bg-white/[0.05] px-1.5 py-0.5 text-gray-400">{col.count}</span>
                  </div>
                  <div className="space-y-2">
                    {col.deals.map((d) => (
                      <div key={d.name} className="rounded-xl border border-white/[0.05] bg-white/[0.02] p-2.5">
                        <div className="flex items-center gap-2">
                          <div className={`grid h-6 w-6 place-items-center rounded-md text-[10px] font-medium ${d.color}`}>
                            {d.name.slice(0, 2)}
                          </div>
                          <div className="min-w-0 flex-1">
                            <div className="truncate text-xs font-medium">{d.name}</div>
                            <div className="truncate text-[10px] text-gray-500">{d.person}</div>
                          </div>
                        </div>
                        <div className="mt-1.5 flex items-center justify-between text-[10px]">
                          <span className="text-gray-300">{d.value}</span>
                          {d.days && <span className="text-gray-500">{d.days}</span>}
                        </div>
                      </div>
                    ))}
                    <div className="text-center text-[10px] text-gray-500">+ {col.more} more</div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Meta Ads Intelligence */}
          <div className="rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
            <div className="mb-4 text-sm font-medium">Meta Ads Intelligence</div>
            <div className="grid gap-4 lg:grid-cols-2">
              <div className="rounded-xl border border-emerald-500/20 bg-emerald-500/[0.04] p-4">
                <div className="mb-3 flex items-start justify-between">
                  <div className="flex items-center gap-2">
                    <div className="grid h-7 w-7 place-items-center rounded-lg bg-emerald-500/20 text-emerald-400">∞</div>
                    <div>
                      <div className="text-sm font-medium">Retargeting – Lookalike 1%</div>
                      <div className="text-[11px] text-gray-400">High ROAS · Consistent Performance</div>
                    </div>
                  </div>
                  <span className="rounded-full bg-emerald-500/15 px-2 py-0.5 text-[10px] font-medium text-emerald-400">Scale Winner</span>
                </div>
                <div className="h-8">
                  <svg viewBox="0 0 200 30" className="h-full w-full" preserveAspectRatio="none">
                    <path d="M0 20 C30 18, 50 15, 80 12 S130 8, 200 6" fill="none" stroke="#34d399" strokeWidth="1.5" />
                  </svg>
                </div>
                <div className="mt-3 grid grid-cols-3 gap-4 text-xs">
                  <div><div className="text-gray-500">ROAS</div><div className="font-medium">4.82x</div></div>
                  <div><div className="text-gray-500">CPA</div><div className="font-medium">$18.21</div></div>
                  <div><div className="text-gray-500">Spend</div><div className="font-medium">$14,382</div></div>
                </div>
              </div>

              <div className="rounded-xl border border-rose-500/20 bg-rose-500/[0.04] p-4">
                <div className="mb-3 flex items-start justify-between">
                  <div className="flex items-center gap-2">
                    <div className="grid h-7 w-7 place-items-center rounded-lg bg-rose-500/20 text-rose-400">×</div>
                    <div>
                      <div className="text-sm font-medium">Prospecting – Interest: SaaS Tools</div>
                      <div className="text-[11px] text-gray-400">Rising CPA · Low Win Rate</div>
                    </div>
                  </div>
                  <span className="rounded-full bg-rose-500/15 px-2 py-0.5 text-[10px] font-medium text-rose-400">Pause Fatigue</span>
                </div>
                <div className="h-8">
                  <svg viewBox="0 0 200 30" className="h-full w-full" preserveAspectRatio="none">
                    <path d="M0 8 C30 10, 50 14, 80 16 S130 20, 200 24" fill="none" stroke="#fb7185" strokeWidth="1.5" />
                  </svg>
                </div>
                <div className="mt-3 grid grid-cols-3 gap-4 text-xs">
                  <div><div className="text-gray-500">ROAS</div><div className="font-medium">1.12x</div></div>
                  <div><div className="text-gray-500">CPA</div><div className="font-medium">$71.34</div></div>
                  <div><div className="text-gray-500">Spend</div><div className="font-medium">$9,217</div></div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
  )
}