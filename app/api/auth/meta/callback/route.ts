import { NextRequest, NextResponse } from 'next/server'

export async function GET(req: NextRequest) {
  const code = req.nextUrl.searchParams.get('code')
  // Exchange code for token, store in Supabase, redirect to dashboard
  // Full implementation: call Graph API, long-lived token, save to social_connections
  return NextResponse.redirect(new URL('/?connected=1', req.url))
}