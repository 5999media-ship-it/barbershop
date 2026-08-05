import 'server-only'

import { cookies } from 'next/headers'
import { redirect } from 'next/navigation'

import { createClient } from '@/lib/supabase/server'
import type { AppRole, Barber, Shop } from '@/lib/supabase/database.types'

const ACTIVE_SHOP_COOKIE = 'bb_shop'

export interface DashboardContext {
  userId: string
  email: string
  shops: Shop[]
  shop: Shop
  role: AppRole
  /** Het barber-record van deze gebruiker binnen de actieve shop, indien aanwezig. */
  barber: Barber | null
  canManage: boolean
  isPlatformAdmin: boolean
}

/**
 * Haalt de context op voor elke dashboardpagina.
 *
 * Merk op dat we hier nergens "mag deze gebruiker deze shop zien" hoeven te
 * checken: de query op shops levert dankzij RLS alleen shops op waar de
 * gebruiker lid van is. De autorisatie zit in de database, niet in deze functie.
 */
export async function getDashboardContext(): Promise<DashboardContext> {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) redirect('/login')

  const [{ data: memberships }, { data: profile }] = await Promise.all([
    supabase
      .from('shop_members')
      .select('shop_id, role, is_active')
      .eq('user_id', user.id)
      .eq('is_active', true),
    supabase
      .from('profiles')
      .select('is_platform_admin')
      .eq('id', user.id)
      .maybeSingle<{ is_platform_admin: boolean }>(),
  ])

  const isPlatformAdmin = profile?.is_platform_admin ?? false
  const shopIds = (memberships ?? []).map((m) => m.shop_id as string)

  // Een platformbeheerder is nergens lid van maar mag overal bij. RLS staat
  // hem de volledige lijst al toe; hier laten we het membership-filter dus weg
  // in plaats van een aparte, ruimere query te schrijven.
  const query = supabase.from('shops').select('*').order('name')
  const { data: shopRows } = isPlatformAdmin ? await query : await query.in('id', shopIds)

  const shops = (shopRows ?? []) as Shop[]
  if (shops.length === 0) redirect('/salon-aanmaken')

  const cookieStore = await cookies()
  const preferred = cookieStore.get(ACTIVE_SHOP_COOKIE)?.value
  const shop = shops.find((s) => s.id === preferred) ?? shops[0]!

  const role = ((memberships ?? []).find((m) => m.shop_id === shop.id)?.role ??
    (isPlatformAdmin ? 'shop_owner' : 'barber')) as AppRole

  const { data: barberRow } = await supabase
    .from('barbers')
    .select('*')
    .eq('shop_id', shop.id)
    .eq('user_id', user.id)
    .maybeSingle<Barber>()

  return {
    userId: user.id,
    email: user.email ?? '',
    shops,
    shop,
    role,
    barber: barberRow ?? null,
    canManage: isPlatformAdmin || role === 'shop_owner' || role === 'manager',
    isPlatformAdmin,
  }
}

export { ACTIVE_SHOP_COOKIE }
