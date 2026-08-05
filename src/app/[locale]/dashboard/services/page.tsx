import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import ServiceEditor from '@/components/dashboard/ServiceEditor'
import type { Service } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

export default async function ServicesPage() {
  const ctx = await getDashboardContext()
  const supabase = await createClient()

  const { data } = await supabase
    .from('services')
    .select('*')
    .eq('shop_id', ctx.shop.id)
    .order('sort_order')

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Behandelingen</h1>
        <p className="mt-1 text-sm text-ink-400">
          Duur en prijs bepalen wat de klant ziet én wat er in de agenda geblokkeerd wordt.
          Opruimtijd telt mee voor de bezetting, maar niet voor de prijs.
        </p>
      </header>

      <ServiceEditor shopId={ctx.shop.id} services={(data ?? []) as Service[]} />
    </>
  )
}
