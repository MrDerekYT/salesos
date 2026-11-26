import './globals.css'
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Sales OS — Close More on Facebook',
  description: 'The sales operating system that turns Facebook into your highest-converting channel.',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-[#0a0a0f]">{children}</body>
    </html>
  )
}