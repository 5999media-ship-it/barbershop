import type { Metadata } from 'next'
import { getTranslations, setRequestLocale } from 'next-intl/server'

import LoginForm from '@/components/dashboard/LoginForm'
import { Link } from '@/i18n/navigation'

type Params = Promise<{ locale: string }>

export const dynamic = 'force-dynamic'

export async function generateMetadata({ params }: { params: Params }): Promise<Metadata> {
  const { locale } = await params
  const t = await getTranslations({ locale, namespace: 'auth' })
  return { title: t('title'), robots: { index: false, follow: false } }
}

export default async function LoginPage({
  params,
  searchParams,
}: {
  params: Params
  searchParams: Promise<{ next?: string; error?: string }>
}) {
  const { locale } = await params
  const { next, error } = await searchParams
  setRequestLocale(locale)

  const t = await getTranslations({ locale, namespace: 'auth' })

  return (
    <main className="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-16">
      <Link href="/" className="mb-8 text-sm text-ink-400 hover:text-brass-300">
        ← {t('backToSite')}
      </Link>
      <h1 className="text-3xl font-semibold tracking-tight">{t('title')}</h1>
      <p className="mt-2 mb-8 text-ink-300">{t('subtitle')}</p>
      <LoginForm nextPath={next ?? '/dashboard'} initialError={error} />
    </main>
  )
}
