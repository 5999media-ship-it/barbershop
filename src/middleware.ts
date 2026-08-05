import createIntlMiddleware from 'next-intl/middleware'
import { NextResponse, type NextRequest } from 'next/server'

import { routing } from '@/i18n/routing'
import { updateSession } from '@/lib/supabase/middleware'

const intlMiddleware = createIntlMiddleware(routing)

/**
 * LET OP de locatie van dit bestand. Next.js zoekt middleware in de wortel van
 * het project OF in src/ — maar niet allebei. Zodra je een src/-map hebt, is
 * src/middleware.ts de enige plek waar hij hem oppikt. Staat hij ernaast in de
 * wortel, dan wordt hij zonder enige waarschuwing genegeerd: de build slaagt,
 * de site draait, en je taalroutering en route-beveiliging doen gewoon niets.
 *
 * Twee taken in één middleware, want Next.js staat er maar één toe:
 * de taal bepalen (next-intl) en de sessie verversen (Supabase).
 *
 * De volgorde is niet vrijblijvend. next-intl bouwt de response op — soms een
 * redirect naar /en, meestal een interne rewrite van / naar /nl. Die response
 * is leidend; Supabase schrijft zijn cookies er alleen op.
 *
 * Draai je het om en laat je Supabase de response maken, dan komt daar
 * `x-middleware-next: 1` op te staan en negeert Next de rewrite van next-intl.
 * /nl en /en blijven dan werken, maar de kale / valt om.
 */
export async function middleware(request: NextRequest) {
  const response = intlMiddleware(request)

  // Echte redirect (bijvoorbeeld naar /en op basis van de browsertaal):
  // daar valt niets meer aan te verversen.
  if (response.status >= 300 && response.status < 400) {
    return response
  }

  const user = await updateSession(request, response)

  // Taalprefix eraf voordat we op routes matchen: /en/dashboard is dezelfde
  // beveiligde route als /dashboard. Bij het doorsturen zetten we de prefix er
  // weer voor, zodat de bezoeker in zijn eigen taal blijft.
  const { pathname } = request.nextUrl
  const segments = pathname.split('/')
  const maybeLocale = segments[1] ?? ''
  const hasPrefix = (routing.locales as readonly string[]).includes(maybeLocale)
  const prefix = hasPrefix ? `/${maybeLocale}` : ''
  const route = hasPrefix ? pathname.slice(prefix.length) || '/' : pathname

  if (!user && route.startsWith('/dashboard')) {
    const url = request.nextUrl.clone()
    url.pathname = `${prefix}/login`
    url.searchParams.set('next', route)
    return NextResponse.redirect(url)
  }

  if (user && route === '/login') {
    const url = request.nextUrl.clone()
    url.pathname = `${prefix}/dashboard`
    url.search = ''
    return NextResponse.redirect(url)
  }

  return response
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
