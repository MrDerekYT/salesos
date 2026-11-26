'use client'

import { useState } from 'react'
import { Facebook, TrendingUp, Users, DollarSign, Target, Zap, ArrowUpRight, Pause, Play, Sparkles } from 'lucide-react'

export default function Home() {
  const [connected, setConnected] = useState(false)

  return (
    <div className="min-h-screen bg-[#050507] text-white">
      {/* Subtle background */}
      <div className="fixed inset-0 bg-[radial-gradient(ellipse_at_top,_var(--tw-gradient-stops))] from-blue-950/20 via-transparent to-transparent pointer-events-none" />

      <div className="relative z-10 max-w-7xl mx-auto px-6 py-8 md:py-12">
        {/* Top bar */}
        <div className="flex items-center justify-between mb-12">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-blue-500 to-violet-600 flex items-center justify-center">
              <Sparkles className="w-5 h-5" />
            </div>
            <span className="text-xl font-semibold tracking-tight">Sales OS</span>
          </div>
          <button
            onClick={() => setConnected(true)}
            className={`flex items-center gap-2 px-5 py-2.5 rounded-xl text-sm font-medium transition-all ${
              connected
                ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20'
                : 'bg-blue-600 hover:bg-blue-500 text-white shadow-lg shadow-blue-500/20'
            }`}
          >
            <Facebook className="w-4 h-4" />
            {connected ? 'Connected' : 'Connect Facebook'}
          </button>
        </div>

        {/* Hero numbers */}
        <div className="mb-12">
          <p className="text-sm text-gray-500 mb-2">Current win rate</p>
          <div className="flex items-end gap-4">
            <h1 className="text-7xl md:text-8xl font-bold tracking-tighter bg-gradient-to-b from-white to-gray-400 bg-clip-text text-transparent">
              87%
            </h1>
            <div className="mb-4 flex items-center gap-1 text-emerald-400 text-lg font-medium">
              <ArrowUpRight className="w-5 h-5" /> +12%
            </div>
          </div>
          <p className="mt-3 text-gray-400 max-w-xl text-lg">
            Facebook leads → optimized creatives → closed deals. The system that makes high conversion feel automatic.
          </p>
        </div>

        {/* KPI row */}
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-10">
          {[
            { icon: DollarSign, label: 'Pipeline', value: '$284.5k', sub: '+23% this month' },
            { icon: Users, label: 'Facebook Leads', value: '142', sub: '38 new this week' },
            { icon: Target, label: 'Avg Deal', value: '$4,820', sub: 'Across 3 stages' },
            { icon: TrendingUp, label: 'ROAS', value: '4.8x', sub: 'Above target' },
          ].map((item) => (
            <div key={item.label} className="group relative rounded-2xl border border-white/5 bg-white/[0.02] p-5 hover:bg-white/[0.04] transition-colors">
              <item.icon className="w-5 h-5 text-blue-400 mb-4" />
              <div className="text-2xl font-semibold tracking-tight">{item.value}</div>
              <div className="text-sm text-gray-500 mt-1">{item.label}</div>
              <div className="text-xs text-emerald-400/80 mt-2">{item.sub}</div>
            </div>
          ))}
        </div>

        {/* Main grid */}
        <div className="grid lg:grid-cols-5 gap-6">
          {/* Pipeline */}
          <div className="lg:col-span-3 rounded-2xl border border-white/5 bg-white/[0.02] p-6">
            <div className="flex items-center justify-between mb-6">
              <h2 className="font-medium">Active Pipeline</h2>
              <span className="text-xs text-gray-500">44 deals</span>
            </div>
            <div className="space-y-2">
              {[
                { stage: 'New Lead', count: 18, color: 'bg-blue-500' },
                { stage: 'Qualified', count: 12, color: 'bg-indigo-500' },
                { stage: 'Proposal', count: 7, color: 'bg-violet-500' },
                { stage: 'Negotiation', count: 4, color: 'bg-amber-500' },
                { stage: 'Won', count: 3, color: 'bg-emerald-500' },
              ].map((s) => (
                <div key={s.stage} className="flex items-center gap-4 py-2.5">
                  <div className={`w-1.5 h-6 rounded-full ${s.color}`} />
                  <div className="flex-1 text-sm">{s.stage}</div>
                  <div className="text-sm font-medium tabular-nums">{s.count}</div>
                </div>
              ))}
            </div>
          </div>

          {/* Meta Intelligence */}
          <div className="lg:col-span-2 rounded-2xl border border-white/5 bg-white/[0.02] p-6">
            <h2 className="font-medium mb-5">Meta Intelligence</h2>
            <div className="space-y-3">
              <div className="p-4 rounded-xl bg-emerald-500/5 border border-emerald-500/10">
                <div className="flex items-center gap-2 text-emerald-400 text-sm font-medium mb-1">
                  <Play className="w-3.5 h-3.5" /> Scale Winner
                </div>
                <p className="text-sm text-gray-300">Creative #4 · CPL $12.40</p>
                <p className="text-xs text-gray-500 mt-1">Recommend +30% budget</p>
              </div>

              <div className="p-4 rounded-xl bg-red-500/5 border border-red-500/10">
                <div className="flex items-center gap-2 text-red-400 text-sm font-medium mb-1">
                  <Pause className="w-3.5 h-3.5" /> Pause Fatigue
                </div>
                <p className="text-sm text-gray-300">Cold Interest · Freq 5.2</p>
                <p className="text-xs text-gray-500 mt-1">Creative exhausted</p>
              </div>

              <div className="p-4 rounded-xl bg-blue-500/5 border border-blue-500/10">
                <div className="flex items-center gap-2 text-blue-400 text-sm font-medium mb-1">
                  <Sparkles className="w-3.5 h-3.5" /> 3 New Hooks
                </div>
                <p className="text-sm text-gray-300">Generated from top performers</p>
              </div>
            </div>
          </div>
        </div>

        <footer className="mt-16 text-center text-xs text-gray-600">
          Sales OS · Built for people who close on Facebook
        </footer>
      </div>
    </div>
  )
}