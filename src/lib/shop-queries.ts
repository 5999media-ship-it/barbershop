import 'server-only'

import { createClient } from '@/lib/supabase/server'
import type { Barber, Service, Shop, WorkingHour } from '@/lib/supabase/database.types'

export interface ShopBundle {
  shop: Shop
  services: Service[]
  barbers: Barber[]
  /** service_id -> barber_id[] */
  serviceBarbers: Record<string, string[]>
  workingHours: WorkingHour[]
}

/**
 * Haalt alles op wat een publieke shoppagina nodig heeft in één ronde.
 *
 * Alle queries lopen via de anon-client, dus RLS bepaalt wat er terugkomt. Een
 * niet-gepubliceerde shop levert hier gewoon null op — er is geen aparte
 * "is hij zichtbaar" check nodig die uit de pas kan gaan lopen.
 */
export async function getShopBundle(slug: string): Promise<ShopBundle | null> {
  const supabase = await createClient()

  const { data: shop } = await supabase
    .from('shops')
    .select('*')
    .eq('slug', slug.toLowerCase())
    .maybeSingle<Shop>()

  if (!shop) return null

  const [servicesRes, barbersRes, linkRes, hoursRes] = await Promise.all([
    supabase
      .from('services')
      .select('*')
      .eq('shop_id', shop.id)
      .eq('is_active', true)
      .order('sort_order'),
    supabase
      .from('barbers')
      .select('*')
      .eq('shop_id', shop.id)
      .eq('is_active', true)
      .order('sort_order'),
    supabase.from('barber_services').select('barber_id, service_id'),
    supabase.from('working_hours').select('*'),
  ])

  const barbers = (barbersRes.data ?? []) as Barber[]
  const barberIds = new Set(barbers.map((b) => b.id))

  const serviceBarbers: Record<string, string[]> = {}
  for (const row of (linkRes.data ?? []) as Array<{ barber_id: string; service_id: string }>) {
    if (!barberIds.has(row.barber_id)) continue
    ;(serviceBarbers[row.service_id] ??= []).push(row.barber_id)
  }

  return {
    shop,
    services: (servicesRes.data ?? []) as Service[],
    barbers,
    serviceBarbers,
    workingHours: ((hoursRes.data ?? []) as WorkingHour[]).filter((h) => barberIds.has(h.barber_id)),
  }
}

/** Alle gepubliceerde shops — voor de sitemap en de homepage. */
export async function listPublishedShops(): Promise<Pick<Shop, 'slug' | 'city' | 'name' | 'tagline' | 'updated_at'>[]> {
  const supabase = await createClient()
  const { data } = await supabase
    .from('shops')
    .select('slug, city, name, tagline, updated_at')
    .order('name')
  return (data ?? []) as Pick<Shop, 'slug' | 'city' | 'name' | 'tagline' | 'updated_at'>[]
}

export { citySlug } from '@/lib/slug'
