import 'server-only'

import { createClient as createSupabaseClient } from '@supabase/supabase-js'
import { requiredEnv } from './server'
import { requirePublicEnv } from '@/lib/env'

/**
 * Service-role client. Omzeilt ALLE RLS-policies.
 *
 * Regels:
 *  - Alleen aanroepen vanuit Route Handlers, Server Actions of Edge Functions.
 *  - Nooit een gebruiker een filter laten aanleveren dat rechtstreeks in een
 *    query belandt; je hebt hier geen vangnet meer.
 *  - `import 'server-only'` zorgt dat de build breekt zodra dit bestand per
 *    ongeluk in een client component belandt.
 */
export function createAdminClient() {
  return createSupabaseClient(
    requirePublicEnv().supabaseUrl,
    requiredEnv('SUPABASE_SERVICE_ROLE_KEY'),
    { auth: { persistSession: false, autoRefreshToken: false } },
  )
}
