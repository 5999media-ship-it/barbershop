import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import OwnProfile from '@/components/dashboard/OwnProfile'
import { Alert } from '@/components/ui'
import type { Service } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

/**
 * Zelfbeheer voor de kapper: foto, introductie en het eigen tarief.
 * Wat hier níet staat is net zo belangrijk: naam, actief-status en welke
 * behandelingen hij doet blijven bij de admin.
 */
export default async function OwnProfilePage() {
  const ctx = await getDashboardContext()

  if (!ctx.barber) {
    return (
      <Alert tone="info">
        Je account is nog niet aan een barber gekoppeld. Vraag de eigenaar om je toe te voegen
        bij Team.
      </Alert>
    )
  }

  const supabase = await createClient()
  const [servicesRes, linksRes] = await Promise.all([
    supabase.from('services').select('*').eq('shop_id', ctx.shop.id).order('sort_order'),
    supabase
      .from('barber_services')
      .select('service_id, price_cents')
      .eq('barber_id', ctx.barber.id),
  ])

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Mijn profiel</h1>
        <p className="mt-1 text-sm text-ink-400">
          Je foto en introductie staan op de publieke pagina van {ctx.shop.name}. Je tarief
          geldt alleen voor jouw stoel — collega&apos;s kunnen een ander bedrag hanteren.
        </p>
      </header>

      <OwnProfile
        barber={ctx.barber}
        services={(servicesRes.data ?? []) as Service[]}
        prices={(linksRes.data ?? []) as Array<{ service_id: string; price_cents: number | null }>}
        currency={ctx.shop.currency}
      />
    </>
  )
}
