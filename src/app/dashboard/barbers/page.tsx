import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import BarberEditor from '@/components/dashboard/BarberEditor'
import type { Barber, Service } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

export default async function BarbersPage() {
  const ctx = await getDashboardContext()
  const supabase = await createClient()

  const [barbersRes, servicesRes, linkRes] = await Promise.all([
    supabase.from('barbers').select('*').eq('shop_id', ctx.shop.id).order('sort_order'),
    supabase.from('services').select('*').eq('shop_id', ctx.shop.id).order('sort_order'),
    supabase.from('barber_services').select('barber_id, service_id'),
  ])

  const barbers = (barbersRes.data ?? []) as Barber[]
  const services = (servicesRes.data ?? []) as Service[]
  const links = (linkRes.data ?? []) as Array<{ barber_id: string; service_id: string }>

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Team</h1>
        <p className="mt-1 text-sm text-ink-400">
          Een barber verschijnt pas in de boekingsflow als hij minimaal één behandeling doet
          én werktijden heeft.
        </p>
      </header>

      <BarberEditor
        shopId={ctx.shop.id}
        barbers={barbers}
        services={services}
        links={links}
      />
    </>
  )
}
