import type { Metadata } from 'next'
import { Link } from '@/i18n/navigation'

import { getTranslations } from 'next-intl/server'

import { Badge, Button } from '@/components/ui'
import ShopSwitcher from '@/components/dashboard/ShopSwitcher'
import { getDashboardContext } from '@/lib/dashboard'
import { signOut } from '@/actions/auth'
import { citySlug } from '@/lib/slug'

// Nooit prerenderen: deze layout leest de sessie van de ingelogde gebruiker.
// Zonder deze regel bakt Next de redirect naar /login in als statische HTML.
export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Dashboard',
  robots: { index: false, follow: false },
}

type NavItem = { href: string; key: string; when: 'all' | 'manager' | 'barber' | 'platform' }

const NAV: NavItem[] = [
  { href: '/dashboard', key: 'agenda', when: 'all' },
  { href: '/dashboard/bookings', key: 'bookings', when: 'all' },
  { href: '/dashboard/hours', key: 'hours', when: 'all' },
  { href: '/dashboard/profiel', key: 'profile', when: 'barber' },
  { href: '/dashboard/services', key: 'services', when: 'manager' },
  { href: '/dashboard/barbers', key: 'team', when: 'manager' },
  { href: '/dashboard/settings', key: 'settings', when: 'manager' },
  { href: '/dashboard/platform', key: 'platform', when: 'platform' },
]

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const ctx = await getDashboardContext()
  const t = await getTranslations('dashboard')
  const tn = await getTranslations('nav')

  return (
    <div className="min-h-screen">
      <header className="border-b border-ink-800 bg-ink-900">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 px-5 py-4">
          <div className="flex items-center gap-3">
            <ShopSwitcher shops={ctx.shops} activeId={ctx.shop.id} />
            {!ctx.shop.is_published && <Badge tone="danger">{t('notPublished')}</Badge>}
          </div>

          <div className="flex items-center gap-3 text-sm">
            <Link
              href={`/kapper/${citySlug(ctx.shop.city)}/${ctx.shop.slug}`}
              className="text-ink-400 hover:text-brass-300"
              target="_blank"
            >
              {tn('viewPublicPage')} ↗
            </Link>
            <form action={signOut}>
              <Button variant="ghost" size="sm" type="submit">
                {tn('logout')}
              </Button>
            </form>
          </div>
        </div>

        <nav className="mx-auto max-w-5xl overflow-x-auto px-5">
          <ul className="flex gap-1 pb-1">
            {NAV.filter((item) =>
              item.when === 'all'
                ? true
                : item.when === 'manager'
                  ? ctx.canManage
                  : item.when === 'barber'
                    ? Boolean(ctx.barber)
                    : ctx.isPlatformAdmin,
            ).map((item) => (
              <li key={item.href}>
                <Link
                  href={item.href}
                  className="inline-block whitespace-nowrap rounded-t-lg px-3.5 py-2.5 text-sm text-ink-300 hover:bg-ink-850 hover:text-brass-300"
                >
                  {t(item.key)}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-5 py-8">{children}</main>
    </div>
  )
}
