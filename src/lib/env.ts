/**
 * Runtime-configuratie.
 *
 * Waarom niet gewoon `process.env.NEXT_PUBLIC_...` overal?
 * Omdat Next elke variabele met het `NEXT_PUBLIC_`-voorvoegsel tijdens de build
 * letterlijk in de bundle vervangt. Je bouwt dan één artefact dat aan één
 * Supabase-project vastzit: van omgeving wisselen betekent opnieuw bouwen.
 *
 * Deze module leest de waarden bij elke request uit de echte omgeving. De
 * browser krijgt ze mee via een klein script in de layout (zie `PublicEnvScript`).
 * Zo is dezelfde build bruikbaar voor staging én productie.
 *
 * De `NEXT_PUBLIC_`-varianten blijven als fallback bestaan, zodat `npm run dev`
 * met een bestaande `.env.local` gewoon blijft werken.
 */

export interface PublicEnv {
  supabaseUrl: string
  supabaseAnonKey: string
  siteUrl: string
}

export function siteUrl(): string {
  return (
    process.env.SITE_URL ||
    process.env.NEXT_PUBLIC_SITE_URL ||
    // Netlify zet URL / DEPLOY_PRIME_URL automatisch per deploy.
    process.env.URL ||
    process.env.DEPLOY_PRIME_URL ||
    // Vercel doet hetzelfde, alleen zonder schema.
    (process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : '') ||
    'http://localhost:3000'
  ).replace(/\/+$/, '')
}

export function publicEnv(): PublicEnv {
  return {
    supabaseUrl: process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || '',
    supabaseAnonKey:
      process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '',
    siteUrl: siteUrl(),
  }
}

/**
 * Alleen serverside. Gooit een begrijpelijke fout in plaats van een vage
 * "Invalid URL" ergens diep in supabase-js.
 */
export function requirePublicEnv(): PublicEnv {
  const env = publicEnv()
  const missing: string[] = []
  if (!env.supabaseUrl) missing.push('SUPABASE_URL')
  if (!env.supabaseAnonKey) missing.push('SUPABASE_ANON_KEY')

  if (missing.length > 0) {
    throw new Error(
      `Ontbrekende omgevingsvariabelen: ${missing.join(', ')}. ` +
        'Zet ze in Netlify onder Site configuration → Environment variables, ' +
        'of lokaal in .env.local (zie .env.example).',
    )
  }
  return env
}
