'use client'

import { createBrowserClient } from '@supabase/ssr'
import type { PublicEnv } from '@/lib/env'

declare global {
  interface Window {
    __PUBLIC_ENV__?: PublicEnv
  }
}

/**
 * Browser-client. Draait met de publishable/anon key en dus volledig onder RLS.
 * Er staat bewust geen enkele geheime sleutel in de bundle.
 *
 * De configuratie komt uit `window.__PUBLIC_ENV__`, dat de server per request
 * meestuurt (zie PublicEnvScript). De `process.env`-fallback is er voor
 * `npm run dev` en voor tests.
 */
export function createClient() {
  const runtime = typeof window !== 'undefined' ? window.__PUBLIC_ENV__ : undefined

  const url = runtime?.supabaseUrl || process.env.NEXT_PUBLIC_SUPABASE_URL || ''
  const key = runtime?.supabaseAnonKey || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || ''

  if (!url || !key) {
    throw new Error(
      'Supabase-configuratie ontbreekt. Zet SUPABASE_URL en SUPABASE_ANON_KEY in je omgeving.',
    )
  }

  return createBrowserClient(url, key)
}
