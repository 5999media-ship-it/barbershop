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

  const { data: memberships } = await supabase
    .from('shop_members')
    .select('shop_id, role, is_active')
    .eq('user_id', user.id)
    .eq('is_active', true)

  const shopIds = (memberships ?? []).map((m) => m.shop_id as string)
  if (shopIds.length === 0) redirect('/salon-aanmaken')

  const { data: shopRows } = await supabase
    .from('shops')
    .select('*')
    .in('id', shopIds)
    .order('name')

  const shops = (shopRows ?? []) as Shop[]
  if (shops.length === 0) redirect('/salon-aanmaken')

  const cookieStore = await cookies()
  const preferred = cookieStore.get(ACTIVE_SHOP_COOKIE)?.value
  const shop = shops.find((s) => s.id === preferred) ?? shops[0]!

  const role = ((memberships ?? []).find((m) => m.shop_id === shop.id)?.role ??
    'barber') as AppRole

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
    canManage: role === 'shop_owner' || role === 'manager',
  }
}

export { ACTIVE_SHOP_COOKIE }
