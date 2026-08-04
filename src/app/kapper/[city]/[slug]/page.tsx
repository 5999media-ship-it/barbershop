import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'

import { Badge, Button, Card } from '@/components/ui'
import { citySlug, getShopBundle } from '@/lib/shop-queries'
import { siteUrl } from '@/lib/env'
import { formatDuration, formatMoney, WEEKDAYS_NL } from '@/lib/format'

type Params = Promise<{ city: string; slug: string }>

export const revalidate = 300 // vijf minuten ISR: snel én actueel genoeg

// ---------------------------------------------------------------------------
// SEO-metadata
// ---------------------------------------------------------------------------
export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { slug } = await params
  const bundle = await getShopBundle(slug)
  if (!bundle) return { title: 'Salon niet gevonden' }

  const { shop, services } = bundle
  const city = shop.city ?? ''
  const cheapest = services.length
    ? Math.min(...services.map((s) => s.price_cents))
    : null

  const title = `${shop.name} — kapper in ${city} | online afspraak maken`
  const description =
    shop.tagline ??
    `Maak online een afspraak bij ${shop.name} in ${city}. ${services
      .slice(0, 3)
      .map((s) => s.name)
      .join(', ')}${cheapest !== null ? ` vanaf ${formatMoney(cheapest, shop.currency)}` : ''}. Direct bevestigd.`

  const path = `/kapper/${citySlug(shop.city)}/${shop.slug}`

  return {
    title,
    description,
    alternates: { canonical: path },
    openGraph: {
      title,
      description,
      url: path,
      images: shop.cover_url ? [{ url: shop.cover_url }] : undefined,
    },
  }
}

// ---------------------------------------------------------------------------
// Pagina
// ---------------------------------------------------------------------------
export default async function ShopPage({ params }: { params: Params }) {
  const { city, slug } = await params
  const bundle = await getShopBundle(slug)
  if (!bundle) notFound()

  const { shop, services, barbers, workingHours } = bundle

  // Canonieke URL afdwingen: /kapper/verkeerde-stad/junique-fades stuurt door.
  const canonicalCity = citySlug(shop.city)
  if (city !== canonicalCity) {
    redirect(`/kapper/${canonicalCity}/${shop.slug}`)
  }

  const base = siteUrl()
  const bookHref = `/kapper/${canonicalCity}/${shop.slug}/boeken`
  const address = [
    [shop.street, shop.house_number].filter(Boolean).join(' '),
    [shop.postal_code, shop.city].filter(Boolean).join(' '),
  ]
    .filter(Boolean)
    .join(', ')

  const priceRange = services.length
    ? `${formatMoney(Math.min(...services.map((s) => s.price_cents)), shop.currency)} – ${formatMoney(
        Math.max(...services.map((s) => s.price_cents)),
        shop.currency,
      )}`
    : undefined

  // Openingstijden van de shop = de unie van alle barberroosters.
  const openingByDay = new Map<number, { open: string; close: string }>()
  for (const wh of workingHours) {
    const cur = openingByDay.get(wh.weekday)
    openingByDay.set(wh.weekday, {
      open: cur ? (wh.start_time < cur.open ? wh.start_time : cur.open) : wh.start_time,
      close: cur ? (wh.end_time > cur.close ? wh.end_time : cur.close) : wh.end_time,
    })
  }

  const SCHEMA_DAY = [
    'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
  ]

  // -------------------------------------------------------------------------
  // schema.org — dit is wat Google gebruikt voor de lokale resultaten en het
  // "afspraak maken"-blok. Zonder dit ben je onzichtbaar in de map pack.
  // -------------------------------------------------------------------------
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'HairSalon',
    '@id': `${base}${bookHref.replace('/boeken', '')}#business`,
    name: shop.name,
    description: shop.description ?? shop.tagline ?? undefined,
    url: `${base}/kapper/${canonicalCity}/${shop.slug}`,
    telephone: shop.phone ?? undefined,
    email: shop.email ?? undefined,
    image: shop.cover_url ?? shop.logo_url ?? undefined,
    priceRange,
    currenciesAccepted: shop.currency,
    address: {
      '@type': 'PostalAddress',
      streetAddress: [shop.street, shop.house_number].filter(Boolean).join(' ') || undefined,
      postalCode: shop.postal_code ?? undefined,
      addressLocality: shop.city ?? undefined,
      addressRegion: shop.region ?? undefined,
      addressCountry: shop.country_code,
    },
    geo:
      shop.latitude && shop.longitude
        ? { '@type': 'GeoCoordinates', latitude: shop.latitude, longitude: shop.longitude }
        : undefined,
    openingHoursSpecification: [...openingByDay.entries()].map(([day, span]) => ({
      '@type': 'OpeningHoursSpecification',
      dayOfWeek: `https://schema.org/${SCHEMA_DAY[day]}`,
      opens: span.open.slice(0, 5),
      closes: span.close.slice(0, 5),
    })),
    potentialAction: {
      '@type': 'ReserveAction',
      target: {
        '@type': 'EntryPoint',
        urlTemplate: `${base}${bookHref}`,
        inLanguage: 'nl-NL',
        actionPlatform: [
          'https://schema.org/DesktopWebPlatform',
          'https://schema.org/MobileWebPlatform',
        ],
      },
      result: { '@type': 'Reservation', name: 'Afspraak bij de kapper' },
    },
    hasOfferCatalog: {
      '@type': 'OfferCatalog',
      name: 'Behandelingen',
      itemListElement: services.map((s) => ({
        '@type': 'Offer',
        itemOffered: {
          '@type': 'Service',
          name: s.name,
          description: s.description ?? undefined,
        },
        price: (s.price_cents / 100).toFixed(2),
        priceCurrency: shop.currency,
      })),
    },
    employee: barbers.map((b) => ({ '@type': 'Person', name: b.display_name })),
  }

  const breadcrumbLd = {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: [
      { '@type': 'ListItem', position: 1, name: 'Kappers', item: `${base}/` },
      {
        '@type': 'ListItem',
        position: 2,
        name: shop.city ?? 'Nederland',
        item: `${base}/kapper/${canonicalCity}`,
      },
      { '@type': 'ListItem', position: 3, name: shop.name },
    ],
  }

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(breadcrumbLd) }}
      />

      <main className="mx-auto max-w-3xl px-5 pb-24 pt-10">
        {/* Hero */}
        <header className="mb-10">
          <nav aria-label="Kruimelpad" className="mb-4 text-sm text-ink-400">
            <Link href="/" className="hover:text-brass-300">
              Kappers
            </Link>
            <span className="mx-2">/</span>
            <Link href={`/kapper/${canonicalCity}`} className="hover:text-brass-300">
              {shop.city}
            </Link>
          </nav>

          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">{shop.name}</h1>
          {shop.tagline && <p className="mt-3 text-lg text-ink-300">{shop.tagline}</p>}

          <div className="mt-5 flex flex-wrap items-center gap-2">
            {address && <Badge>{address}</Badge>}
            {priceRange && <Badge tone="brass">{priceRange}</Badge>}
            {shop.phone && <Badge>{shop.phone}</Badge>}
          </div>

          <div className="mt-7 flex flex-wrap gap-3">
            <Link href={bookHref}>
              <Button size="lg">Afspraak maken</Button>
            </Link>
            {shop.phone && (
              <a href={`tel:${shop.phone.replace(/\s/g, '')}`}>
                <Button size="lg" variant="ghost">
                  Bellen
                </Button>
              </a>
            )}
          </div>
        </header>

        {shop.description && (
          <section className="mb-12">
            <p className="text-[15px] leading-relaxed text-ink-300">{shop.description}</p>
          </section>
        )}

        {/* Diensten — ook los waardevol voor long-tail zoekwoorden */}
        <section className="mb-12" aria-labelledby="diensten">
          <h2 id="diensten" className="mb-4 text-2xl font-semibold">
            Behandelingen en prijzen
          </h2>
          <ul className="space-y-2">
            {services.map((s) => (
              <li key={s.id}>
                <Card className="flex items-center justify-between gap-4 py-4">
                  <div>
                    <p className="font-medium">{s.name}</p>
                    {s.description && (
                      <p className="mt-0.5 text-sm text-ink-400">{s.description}</p>
                    )}
                    <p className="mt-1 text-xs text-ink-400">
                      {formatDuration(s.duration_minutes)}
                    </p>
                  </div>
                  <div className="shrink-0 text-right">
                    <p className="text-lg font-semibold text-brass-300">
                      {formatMoney(s.price_cents, shop.currency)}
                    </p>
                    <Link
                      href={`${bookHref}?dienst=${s.slug}`}
                      className="text-xs text-ink-400 underline-offset-2 hover:text-brass-300 hover:underline"
                    >
                      Boeken
                    </Link>
                  </div>
                </Card>
              </li>
            ))}
          </ul>
        </section>

        {/* Barbers */}
        <section className="mb-12" aria-labelledby="team">
          <h2 id="team" className="mb-4 text-2xl font-semibold">
            Ons team
          </h2>
          <div className="grid gap-3 sm:grid-cols-3">
            {barbers.map((b) => (
              <Card key={b.id}>
                <p className="font-medium">{b.display_name}</p>
                {b.bio && <p className="mt-1 text-sm text-ink-400">{b.bio}</p>}
              </Card>
            ))}
          </div>
        </section>

        {/* Openingstijden */}
        <section className="mb-12" aria-labelledby="tijden">
          <h2 id="tijden" className="mb-4 text-2xl font-semibold">
            Openingstijden
          </h2>
          <Card className="py-3">
            <dl className="divide-y divide-ink-800">
              {[1, 2, 3, 4, 5, 6, 0].map((day) => {
                const span = openingByDay.get(day)
                return (
                  <div key={day} className="flex justify-between py-2.5 text-sm">
                    <dt className="capitalize text-ink-300">{WEEKDAYS_NL[day]}</dt>
                    <dd className={span ? 'text-ink-100' : 'text-ink-400'}>
                      {span ? `${span.open.slice(0, 5)} – ${span.close.slice(0, 5)}` : 'Gesloten'}
                    </dd>
                  </div>
                )
              })}
            </dl>
          </Card>
          <p className="mt-2 text-xs text-ink-400">
            Tijden in {shop.timezone.replace('_', ' ')}. Per barber kunnen de tijden afwijken;
            de boekingskalender toont de werkelijke beschikbaarheid.
          </p>
        </section>

        <div className="rounded-[16px] border border-brass-500/30 bg-brass-500/5 p-6 text-center">
          <p className="text-lg font-medium">Klaar voor een verse coupe?</p>
          <p className="mt-1 text-sm text-ink-300">
            Direct bevestigd. Gratis annuleren tot {shop.cancel_cutoff_hours} uur van tevoren.
          </p>
          <Link href={bookHref} className="mt-4 inline-block">
            <Button size="lg">Kies je tijd</Button>
          </Link>
        </div>
      </main>
    </>
  )
}
