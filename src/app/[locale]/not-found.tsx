import { useTranslations } from 'next-intl'

import { Link } from '@/i18n/navigation'
import { Button } from '@/components/ui'

export default function NotFound() {
  const t = useTranslations('seo')

  return (
    <main className="mx-auto flex min-h-[70vh] max-w-md flex-col items-center justify-center px-5 text-center">
      <p className="text-sm font-medium uppercase tracking-[0.2em] text-brass-400">404</p>
      <h1 className="mt-3 text-3xl font-semibold">{t('notFoundTitle')}</h1>
      <p className="mt-3 text-ink-300">{t('notFoundBody')}</p>
      <Link href="/" className="mt-7">
        <Button>{t('notFoundButton')}</Button>
      </Link>
    </main>
  )
}
