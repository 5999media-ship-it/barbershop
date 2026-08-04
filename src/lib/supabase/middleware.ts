import { createServerClient, type CookieOptions } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

import { requirePublicEnv } from '@/lib/env'

type CookieToSet = { name: string; value: string; options: CookieOptions }

/**
 * Ververst de Supabase-sessie bij elke request en beschermt /dashboard.
 *
 * Belangrijk: gebruik altijd getUser() en niet getSession() in serverside code.
 * getSession() leest de cookie zonder te valideren; getUser() controleert het
 * token bij Supabase. Het verschil is precies het verschil tussen "de bezoeker
 * zegt dat hij ingelogd is" en "de bezoeker ís ingelogd".
 */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request })

  const env = requirePublicEnv()

  const supabase = createServerClient(
    env.supabaseUrl,
    env.supabaseAnonKey,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet: CookieToSet[]) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          response = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          )
        },
      },
    },
  )

  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { pathname } = request.nextUrl

  if (!user && pathname.startsWith('/dashboard')) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    url.searchParams.set('next', pathname)
    return NextResponse.redirect(url)
  }

  if (user && pathname === '/login') {
    const url = request.nextUrl.clone()
    url.pathname = '/dashboard'
    url.search = ''
    return NextResponse.redirect(url)
  }

  return response
}
