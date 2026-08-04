import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import HoursEditor from '@/components/dashboard/HoursEditor'
import type { Barber, WorkingHour } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

export default async function HoursPage({
  searchParams,
}: {
  searchParams: Promise<{ barber?: string }>
}) {
  const ctx = await getDashboardContext()
  const { barber: barberParam } = await searchParams
  const supabase = await createClient()

  const { data: barberRows } = await supabase
    .from('barbers')
    .select('*')
    .eq('shop_id', ctx.shop.id)
    .order('sort_order')

  const barbers = (barberRows ?? []) as Barber[]

  // Een barber zonder beheerrechten mag alleen zijn eigen rooster zien.
  const selectable = ctx.canManage
    ? barbers
    : barbers.filter((b) => b.id === ctx.barber?.id)

  const selected =
    selectable.find((b) => b.id === barberParam) ?? selectable[0] ?? null

  const { data: hours } = selected
    ? await supabase.from('working_hours').select('*').eq('barber_id', selected.id)
    : { data: [] }

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Werktijden</h1>
        <p className="mt-1 text-sm text-ink-400">
          Tijden in {ctx.shop.timezone}. Twee blokken per dag maakt een lunchpauze mogelijk;
          laat het tweede blok leeg als je doorwerkt.
        </p>
      </header>

      {selected ? (
        <HoursEditor
          barbers={selectable}
          selected={selected}
          hours={(hours ?? []) as WorkingHour[]}
        />
      ) : (
        <p className="text-ink-400">Maak eerst een barber aan.</p>
      )}
    </>
  )
}
