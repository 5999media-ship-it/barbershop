import type { Metadata } from 'next'
import { Link } from '@/i18n/navigation'

import LoginForm from '@/components/dashboard/LoginForm'

export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Inloggen',
  robots: { index: false, follow: false },
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; error?: string }>
}) {
  const { next, error } = await searchParams

  return (
    <main className="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-16">
      <Link href="/" className="mb-8 text-sm text-ink-400 hover:text-brass-300">
        ← Terug naar de site
      </Link>
      <h1 className="text-3xl font-semibold tracking-tight">Inloggen</h1>
      <p className="mt-2 mb-8 text-ink-300">
        Voor salons en barbers. Klanten hoeven geen account te maken.
      </p>
      <LoginForm nextPath={next ?? '/dashboard'} initialError={error} />
    </main>
  )
}
