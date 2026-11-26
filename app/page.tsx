'use client'

import { useState } from 'react'
import { Facebook, TrendingUp, Users, DollarSign, Target, Zap } from 'lucide-react'

export default function Home() {
  const [connected, setConnected] = useState(false)

  return (
    <div className="min-h-screen p-6 md:p-10">
      {/* Hero */}
      <header className="mb-12 text-center">
        <div className="inline-flex items-center gap-2 px-4 py-1 rounded-full bg-blue-500/10 text-blue-400 text-sm mb-4">
          <Zap className="w-4 h-4" /> Facebook-Powered Sales OS
        </div>
        <h1 className="text-5xl md:text-7xl font-bold tracking-tight bg-gradient-to-r from-white to-gray-400 bg-clip-text text-transparent">
          Win Rate 87%
        </h1>
        <p className="mt-4 text-xl text-gray-400 max-w-2xl mx-auto">
          Connect Facebook. Import leads. Optimize ads. Close deals. The system that makes high conversion feel automatic.
        </p>
        <button
          onClick={() => setConnected(true)}
          className="mt-8 px-8 py-4 bg-blue-600 hover:bg-blue-500 rounded-2xl font-semibold text-lg flex items-center gap-3 mx-auto transition-all glow"
        >
          <Facebook className="w-6 h-6" />
          {connected ? 'Facebook Connected' : 'Connect Facebook & Start Winning'}
        </button>
      </header>

      {/* KPIs */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-10">
        {[
          { icon: DollarSign, label: 'Pipeline', value: '$284,500', change: '+23%' },
          { icon: Target, label: 'Win Rate', value: '87%', change: '+12%' },
          { icon: Users, label: 'FB Leads', value: '142', change: '+38%' },
          { icon: TrendingUp, label: 'ROAS', value: '4.8x', change: '+0.6' },
        ].map((k) => (
          <div key={k.label} className="glass rounded-2xl p-6">
            <k.icon className="w-6 h-6 text-blue-400 mb-3" />
            <div className="text-3xl font-bold">{k.value}</div>
            <div className="text-sm text-gray-400 mt-1">{k.label}</div>
            <div className="text-emerald-400 text-sm mt-2">{k.change}</div>
          </div>
        ))}
      </div>

      {/* Pipeline + Ads */}
      <div className="grid md:grid-cols-2 gap-6">
        <div className="glass rounded-2xl p-6">
          <h2 className="text-xl font-semibold mb-4">Active Pipeline</h2>
          <div className="space-y-3">
            {['New Lead', 'Qualified', 'Proposal', 'Negotiation', 'Won'].map((stage, i) => (
              <div key={stage} className="flex items-center justify-between p-3 rounded-xl bg-white/5">
                <span>{stage}</span>
                <span className="text-blue-400 font-medium">{[18, 12, 7, 4, 3][i]}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="glass rounded-2xl p-6">
          <h2 className="text-xl font-semibold mb-4">Meta Ads Intelligence</h2>
          <div className="space-y-4">
            <div className="p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/20">
              <div className="font-medium text-emerald-400">Winner Detected</div>
              <div className="text-sm text-gray-300 mt-1">Creative #4 — CPL $12.40 — Scale budget +30%</div>
            </div>
            <div className="p-4 rounded-xl bg-red-500/10 border border-red-500/20">
              <div className="font-medium text-red-400">Kill Recommended</div>
              <div className="text-sm text-gray-300 mt-1">Ad Set “Cold Interest” — Frequency 5.2 — Creative fatigue</div>
            </div>
            <div className="p-4 rounded-xl bg-blue-500/10 border border-blue-500/20">
              <div className="font-medium text-blue-400">AI Creative Ready</div>
              <div className="text-sm text-gray-300 mt-1">3 new hooks generated from top performers</div>
            </div>
          </div>
        </div>
      </div>

      <footer className="mt-16 text-center text-gray-500 text-sm">
        Sales OS · Powered by Supabase + Vercel · Built on the best open-source Meta tooling
      </footer>
    </div>
  )
}