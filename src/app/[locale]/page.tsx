import type { Metadata } from 'next'
import { getTranslations, setRequestLocale } from 'next-intl/server'

import { Link } from '@/i18n/navigation'

import { Button, Card } from '@/components/ui'
import { citySlug, listPublishedShops } from '@/lib/shop-queries'

export const revalidate = 600

type Params = Promise<{ locale: string }>

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { locale } = await params
  const t = await getTranslations({ locale, namespace: 'seo' })
  return {
    title: t('defaultTitle'),
    description: t('defaultDescription'),
    alternates: { canonical: '/' },
  }
}

export default async function HomePage({ params }: { params: Params }) {
  const { locale } = await params
  setRequestLocale(locale)
  const t = await getTranslations({ locale, namespace: 'home' })
  const shops = await listPublishedShops()

  const byCity = shops.reduce<Record<string, typeof shops>>((acc, shop) => {
    const key = shop.city ?? 'Overig'
    ;(acc[key] ??= []).push(shop)
    return acc
  }, {})

  return (
    <main className="mx-auto max-w-3xl px-5 pb-24 pt-16">
      <section className="mb-16 text-center">
        <p className="mb-4 text-sm font-medium uppercase tracking-[0.2em] text-brass-400">
          {t('eyebrow')}
        </p>
        <h1 className="text-4xl font-semibold leading-tight tracking-tight sm:text-6xl">
          {t('titleLine1')}
          <br />
          <span className="text-brass-300">{t('titleLine2')}</span>
        </h1>
        <p className="mx-auto mt-5 max-w-lg text-lg text-ink-300">{t('subtitle')}</p>
      </section>

      {shops.length === 0 ? (
        <Card className="text-center">
          <p className="font-medium">{t('emptyTitle')}</p>
          <p className="mt-2 text-sm text-ink-400">{t('emptyBody')}</p>
          <Link href="/dashboard" className="mt-5 inline-block">
            <Button>{t('toDashboard')}</Button>
          </Link>
        </Card>
      ) : (
        Object.entries(byCity).map(([city, list]) => (
          <section key={city} className="mb-10">
            <h2 className="mb-4 text-sm font-medium uppercase tracking-wider text-ink-400">
              {city}
            </h2>
            <div className="space-y-2">
              {list.map((shop) => (
                <Link key={shop.slug} href={`/kapper/${citySlug(shop.city)}/${shop.slug}`}>
                  <Card className="transition hover:border-brass-500/60">
                    <p className="font-medium">{shop.name}</p>
                    {shop.tagline && (
                      <p className="mt-0.5 text-sm text-ink-400">{shop.tagline}</p>
                    )}
                  </Card>
                </Link>
              ))}
            </div>
          </section>
        ))
      )}

      <footer className="mt-20 border-t border-ink-800 pt-8 text-sm text-ink-400">
        <p>
          {t('footerQuestion')}{' '}
          <Link href="/login" className="text-brass-300 hover:underline">
            {t('footerLink')}
          </Link>{' '}
          {t('footerTail')}
        </p>
      </footer>
    </main>
  )
}
