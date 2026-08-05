import { notFound } from 'next/navigation'

import PlatformAdmin from '@/components/dashboard/PlatformAdmin'
import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'

export const dynamic = 'force-dynamic'

export interface AdminShopRow {
  id: string
  slug: string
  name: string
  city: string | null
  is_published: boolean
  is_active: boolean
  barber_count: number
  service_count: number
  booking_count: number
  upcoming_count: number
  created_at: string
}

/**
 * Platformbeheer. Alleen bereikbaar voor een platform_admin — en die controle
 * staat niet alleen hier maar ook in de RPC zelf, want een 404 in de UI is
 * geen beveiliging.
 */
export default async function PlatformPage() {
  const ctx = await getDashboardContext()
  if (!ctx.isPlatformAdmin) notFound()

  const supabase = await createClient()
  const { data } = await supabase.rpc('admin_shop_overview')

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Platform</h1>
        <p className="mt-1 text-sm text-ink-400">
          Alle salons op dit platform. Publiceren zet een salon live; offline halen laat
          bestaande afspraken staan maar blokkeert nieuwe boekingen.
        </p>
      </header>

      <PlatformAdmin shops={(data ?? []) as AdminShopRow[]} currentEmail={ctx.email} />
    </>
  )
}
