import { createServerClient, type CookieOptions } from '@supabase/ssr'
import type { NextRequest, NextResponse } from 'next/server'

import { requirePublicEnv } from '@/lib/env'

type CookieToSet = { name: string; value: string; options: CookieOptions }

/**
 * Ververst de Supabase-sessie en schrijft de vernieuwde cookies op een
 * bestaande response.
 *
 * Let op de vorm: deze functie maakt zelf géén response meer aan, maar krijgt
 * er een mee. Dat is essentieel bij het combineren met next-intl. Zou je hier
 * `NextResponse.next()` aanroepen, dan zet Next daar de header
 * `x-middleware-next: 1` op — en die overrulet de rewrite die next-intl nodig
 * heeft om `/` naar `/nl` te sturen. Het gevolg was precies wat we zagen:
 * `/nl` en `/en` werkten, maar de kale `/` viel om.
 *
 * Gebruik altijd getUser() en niet getSession() in serverside code.
 * getSession() leest de cookie zonder te valideren; getUser() controleert het
 * token bij Supabase. Dat is het verschil tussen "de bezoeker zegt dat hij
 * ingelogd is" en "de bezoeker ís ingelogd".
 */
export async function updateSession(
  request: NextRequest,
  response: NextResponse,
): Promise<{ id: string } | null> {
  const env = requirePublicEnv()

  const supabase = createServerClient(env.supabaseUrl, env.supabaseAnonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet: CookieToSet[]) {
        cookiesToSet.forEach(({ name, value, options }) => {
          // Op de request zodat de rest van deze middleware de verse cookie
          // ziet, en op de response zodat de browser hem meekrijgt.
          request.cookies.set(name, value)
          response.cookies.set(name, value, options)
        })
      },
    },
  })

  const {
    data: { user },
  } = await supabase.auth.getUser()

  return user ? { id: user.id } : null
}
