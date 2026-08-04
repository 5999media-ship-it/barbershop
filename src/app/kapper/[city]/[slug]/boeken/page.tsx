import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'

import BookingWizard from '@/components/booking/BookingWizard'
import { citySlug, getShopBundle } from '@/lib/shop-queries'

type Params = Promise<{ city: string; slug: string }>
type Search = Promise<{ dienst?: string }>

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { slug } = await params
  const bundle = await getShopBundle(slug)
  if (!bundle) return { title: 'Salon niet gevonden' }

  return {
    title: `Afspraak maken bij ${bundle.shop.name}`,
    description: `Kies je behandeling, barber en tijd bij ${bundle.shop.name} in ${bundle.shop.city}. Direct bevestigd.`,
    // De boekingsflow zelf hoeft niet geïndexeerd te worden; de shoppagina is
    // de landingspagina. Wel volgen, zodat linkwaarde doorstroomt.
    robots: { index: false, follow: true },
  }
}

export default async function BookPage({
  params,
  searchParams,
}: {
  params: Params
  searchParams: Search
}) {
  const { slug } = await params
  const { dienst } = await searchParams
  const bundle = await getShopBundle(slug)
  if (!bundle) notFound()

  const { shop, services, barbers, serviceBarbers } = bundle

  return (
    <main className="mx-auto max-w-2xl px-5 pb-24 pt-10">
      <header className="mb-9">
        <Link
          href={`/kapper/${citySlug(shop.city)}/${shop.slug}`}
          className="text-sm text-ink-400 hover:text-brass-300"
        >
          ← {shop.name}
        </Link>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">Afspraak maken</h1>
      </header>

      <BookingWizard
        shop={shop}
        services={services}
        barbers={barbers}
        serviceBarbers={serviceBarbers}
        preselectedServiceSlug={dienst}
      />
    </main>
  )
}
