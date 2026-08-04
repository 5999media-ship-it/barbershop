import { createServerClient, type CookieOptions } from '@supabase/ssr'
import { cookies } from 'next/headers'

import { requirePublicEnv } from '@/lib/env'

type CookieToSet = { name: string; value: string; options: CookieOptions }

/**
 * Supabase-client voor Server Components, Server Actions en Route Handlers.
 *
 * Gebruikt de sessiecookie van de bezoeker, dus RLS geldt onverkort. Dit is de
 * client die je in 99% van de gevallen wilt.
 */
export async function createClient() {
  const cookieStore = await cookies()
  const env = requirePublicEnv()

  return createServerClient(env.supabaseUrl, env.supabaseAnonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet: CookieToSet[]) {
        try {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options),
          )
        } catch {
          // Aanroepen vanuit een Server Component: de middleware ververst de
          // sessie al, dus dit mag stil falen.
        }
      },
    },
  })
}

/** Verplichte serverside variabele, met een foutmelding waar je iets aan hebt. */
export function requiredEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(
      `Ontbrekende omgevingsvariabele ${name}. Zet hem in Netlify onder ` +
        'Site configuration → Environment variables, of lokaal in .env.local.',
    )
  }
  return value
}
