import './globals.css'
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Sales OS — Facebook Marketplace Sales Operating System',
  description: 'High-end sales OS for Facebook Marketplace. Inventory, CRM, AI autopilot, and one-click listing fill.',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-ink-950 text-ink-100">{children}</body>
    </html>
  )
}