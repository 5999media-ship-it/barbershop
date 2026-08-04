import type { Metadata } from 'next'
import Link from 'next/link'

import { Badge, Button } from '@/components/ui'
import ShopSwitcher from '@/components/dashboard/ShopSwitcher'
import { getDashboardContext } from '@/lib/dashboard'
import { signOut } from '@/app/login/actions'
import { citySlug } from '@/lib/slug'

export const metadata: Metadata = {
  title: 'Dashboard',
  robots: { index: false, follow: false },
}

const NAV = [
  { href: '/dashboard', label: 'Agenda' },
  { href: '/dashboard/bookings', label: 'Afspraken' },
  { href: '/dashboard/services', label: 'Behandelingen' },
  { href: '/dashboard/barbers', label: 'Team' },
  { href: '/dashboard/hours', label: 'Werktijden' },
  { href: '/dashboard/settings', label: 'Instellingen' },
]

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const ctx = await getDashboardContext()

  return (
    <div className="min-h-screen">
      <header className="border-b border-ink-800 bg-ink-900">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 px-5 py-4">
          <div className="flex items-center gap-3">
            <ShopSwitcher shops={ctx.shops} activeId={ctx.shop.id} />
            {!ctx.shop.is_published && <Badge tone="danger">Niet gepubliceerd</Badge>}
          </div>

          <div className="flex items-center gap-3 text-sm">
            <Link
              href={`/kapper/${citySlug(ctx.shop.city)}/${ctx.shop.slug}`}
              className="text-ink-400 hover:text-brass-300"
              target="_blank"
            >
              Bekijk publieke pagina ↗
            </Link>
            <form action={signOut}>
              <Button variant="ghost" size="sm" type="submit">
                Uitloggen
              </Button>
            </form>
          </div>
        </div>

        <nav className="mx-auto max-w-5xl overflow-x-auto px-5">
          <ul className="flex gap-1 pb-1">
            {NAV.filter((item) => ctx.canManage || item.href === '/dashboard' || item.href === '/dashboard/bookings' || item.href === '/dashboard/hours').map(
              (item) => (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    className="inline-block whitespace-nowrap rounded-t-lg px-3.5 py-2.5 text-sm text-ink-300 hover:bg-ink-850 hover:text-brass-300"
                  >
                    {item.label}
                  </Link>
                </li>
              ),
            )}
          </ul>
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-5 py-8">{children}</main>
    </div>
  )
}
