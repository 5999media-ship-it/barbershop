import type { Metadata, Viewport } from 'next'
import { NextIntlClientProvider, hasLocale } from 'next-intl'
import { getTranslations, setRequestLocale } from 'next-intl/server'
import { notFound } from 'next/navigation'

import PublicEnvScript from '@/components/PublicEnvScript'
import SiteChrome from '@/components/SiteChrome'
import ThemeScript from '@/components/ThemeScript'
import { routing, HTML_LANG, type Locale } from '@/i18n/routing'
import { siteUrl } from '@/lib/env'
import { getThemeChoice } from '@/lib/theme'
import '../globals.css'

type Params = Promise<{ locale: string }>

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }))
}

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { locale } = await params
  const t = await getTranslations({ locale, namespace: 'seo' })

  return {
    metadataBase: new URL(siteUrl()),
    title: { default: t('defaultTitle'), template: `%s | ${t('siteName')}` },
    description: t('defaultDescription'),
    openGraph: {
      type: 'website',
      siteName: t('siteName'),
      locale: HTML_LANG[locale as Locale] ?? 'nl-NL',
    },
    robots: { index: true, follow: true },
  }
}

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#faf9f7' },
    { media: '(prefers-color-scheme: dark)', color: '#0b0b0d' },
  ],
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode
  params: Params
}) {
  const { locale } = await params
  if (!hasLocale(routing.locales, locale)) notFound()

  // Nodig om statische rendering per taal mogelijk te maken.
  setRequestLocale(locale)

  const theme = await getThemeChoice()
  const t = await getTranslations({ locale, namespace: 'common' })

  return (
    <html
      lang={HTML_LANG[locale]}
      className={theme === 'dark' ? 'dark' : undefined}
      // De klasse kan door ThemeScript aangepast worden vóór hydratie;
      // dat is precies de bedoeling en geen echte mismatch.
      suppressHydrationWarning
    >
      <head>
        <ThemeScript choice={theme} />
      </head>
      <body>
        <PublicEnvScript />
        <a href="#main" className="skip-link">
          {t('back')}
        </a>
        <NextIntlClientProvider>
          <div id="main">{children}</div>
          <SiteChrome />
        </NextIntlClientProvider>
      </body>
    </html>
  )
}
