import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'

import { Card } from '@/components/ui'
import { citySlug, listPublishedShops } from '@/lib/shop-queries'
import { siteUrl } from '@/lib/env'

type Params = Promise<{ city: string }>

export const revalidate = 600

/**
 * Stadspagina. Dit is het GEO-anker: één geïndexeerde pagina per stad die
 * intern naar alle salons daar linkt. Zonder zo'n hub-pagina concurreren je
 * salonpagina's met elkaar in plaats van met de rest van het internet.
 */
export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { city } = await params
  const shops = (await listPublishedShops()).filter((s) => citySlug(s.city) === city)
  const cityName = shops[0]?.city ?? city.replace(/-/g, ' ')

  return {
    title: `Kapper in ${cityName} — online afspraak maken`,
    description: `Alle barbershops in ${cityName} die online boeken aanbieden. Kies een salon, kies je tijd en het staat vast.`,
    alternates: { canonical: `/kapper/${city}` },
  }
}

export default async function CityPage({ params }: { params: Params }) {
  const { city } = await params
  const shops = (await listPublishedShops()).filter((s) => citySlug(s.city) === city)
  if (shops.length === 0) notFound()

  const cityName = shops[0]?.city ?? city.replace(/-/g, ' ')

  const base = siteUrl()

  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'ItemList',
    name: `Barbershops in ${cityName}`,
    itemListElement: shops.map((shop, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      url: `${base}/kapper/${city}/${shop.slug}`,
      name: shop.name,
    })),
  }

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <main className="mx-auto max-w-2xl px-5 pb-24 pt-12">
        <nav aria-label="Kruimelpad" className="mb-4 text-sm text-ink-400">
          <Link href="/" className="hover:text-brass-300">
            Kappers
          </Link>
        </nav>
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">
          Kapper in <span className="capitalize">{cityName}</span>
        </h1>
        <p className="mt-3 text-ink-300">
          {shops.length} {shops.length === 1 ? 'salon' : 'salons'} waar je direct online kunt boeken.
        </p>

        <div className="mt-8 space-y-2">
          {shops.map((shop) => (
            <Link key={shop.slug} href={`/kapper/${city}/${shop.slug}`}>
              <Card className="transition hover:border-brass-500/60">
                <p className="font-medium">{shop.name}</p>
                {shop.tagline && <p className="mt-0.5 text-sm text-ink-400">{shop.tagline}</p>}
              </Card>
            </Link>
          ))}
        </div>
      </main>
    </>
  )
}
