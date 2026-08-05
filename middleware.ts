import createIntlMiddleware from 'next-intl/middleware'
import { NextResponse, type NextRequest } from 'next/server'

import { routing } from '@/i18n/routing'
import { updateSession } from '@/lib/supabase/middleware'

const intlMiddleware = createIntlMiddleware(routing)

/**
 * Twee middlewares in één. Next.js staat er maar één toe, dus we ketenen ze:
 *
 *  1. next-intl bepaalt de taal en stuurt zo nodig door naar /en/…
 *  2. Supabase ververst de sessiecookie en bewaakt /dashboard.
 *
 * De volgorde is niet willekeurig. Stuurt next-intl door, dan heeft het geen
 * zin om nog een sessie te verversen voor een response die toch een redirect
 * is. Daarom eerst taal, dan sessie — en de cookies die Supabase zet plakken
 * we op de response die next-intl heeft opgebouwd, zodat er geen verloren gaan.
 */
export async function middleware(request: NextRequest) {
  const intlResponse = intlMiddleware(request)

  // Een echte redirect (taalprefix toevoegen): meteen doorsturen.
  if (intlResponse.status >= 300 && intlResponse.status < 400) {
    return intlResponse
  }

  const authResponse = await updateSession(request)

  // Bewaking van /dashboard heeft voorrang.
  if (authResponse.status >= 300 && authResponse.status < 400) {
    return authResponse
  }

  // Headers van next-intl (o.a. de taalonderhandeling) overnemen…
  intlResponse.headers.forEach((value, key) => {
    if (key.toLowerCase() === 'x-middleware-set-cookie') return
    authResponse.headers.set(key, value)
  })
  // …en de cookies van beide behouden.
  intlResponse.cookies.getAll().forEach((cookie) => {
    authResponse.cookies.set(cookie)
  })

  return authResponse as NextResponse
}

export const config = {
  matcher: [
    /*
     * Alles behalve API-routes, Next.js-interne paden en statische bestanden.
     * Die hebben geen taal en geen sessie nodig.
     */
    '/((?!api|_next/static|_next/image|favicon.ico|robots.txt|sitemap.xml|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif|ico|txt|xml)$).*)',
  ],
}
