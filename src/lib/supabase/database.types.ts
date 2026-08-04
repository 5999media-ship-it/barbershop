/**
 * Handgeschreven typen voor de publieke schema-objecten die de app gebruikt.
 *
 * Zodra je de Supabase CLI hebt gekoppeld kun je dit bestand laten genereren:
 *   npm run db:types
 * Dat is de aanbevolen route: dan lopen types en database gegarandeerd in de pas.
 */

export type BookingStatus = 'pending' | 'confirmed' | 'completed' | 'cancelled' | 'no_show'
export type AppRole = 'platform_admin' | 'shop_owner' | 'manager' | 'barber'

export interface Shop {
  id: string
  slug: string
  name: string
  tagline: string | null
  description: string | null
  phone: string | null
  email: string | null
  website: string | null
  street: string | null
  house_number: string | null
  postal_code: string | null
  city: string | null
  region: string | null
  country_code: string
  latitude: number | null
  longitude: number | null
  instagram_url: string | null
  google_place_id: string | null
  timezone: string
  currency: string
  logo_url: string | null
  cover_url: string | null
  slot_interval_minutes: number
  min_lead_minutes: number
  max_advance_days: number
  cancel_cutoff_hours: number
  max_open_per_customer: number
  is_active: boolean
  is_published: boolean
  notify_email_enabled: boolean
  notify_sms_enabled: boolean
  reminder_hours: number[]
  staff_notify_email: string | null
  reply_to_email: string | null
  created_at: string
  updated_at: string
}

export interface Barber {
  id: string
  shop_id: string
  user_id: string | null
  slug: string
  display_name: string
  bio: string | null
  avatar_url: string | null
  instagram: string | null
  is_active: boolean
  accepts_online_bookings: boolean
  sort_order: number
}

export interface Service {
  id: string
  shop_id: string
  slug: string
  name: string
  description: string | null
  category: string | null
  duration_minutes: number
  buffer_after_minutes: number
  price_cents: number
  is_active: boolean
  sort_order: number
}

export interface WorkingHour {
  id: string
  barber_id: string
  weekday: number
  start_time: string
  end_time: string
}

export interface Booking {
  id: string
  shop_id: string
  barber_id: string
  service_id: string
  customer_id: string | null
  customer_name: string
  customer_email: string
  customer_phone: string
  starts_at: string
  ends_at: string
  service_end_at: string
  status: BookingStatus
  price_cents: number
  currency: string
  notes: string | null
  internal_note: string | null
  source: string
  cancelled_at: string | null
  cancelled_by: string | null
  cancel_reason: string | null
  created_at: string
  updated_at: string
}

export interface ShopMember {
  id: string
  shop_id: string
  user_id: string
  role: AppRole
  is_active: boolean
}

export interface AvailableSlot {
  barber_id: string
  slot_start: string
  slot_end: string
  block_end: string
  price_cents: number
}

export interface AvailableDay {
  day: string
  slot_count: number
  first_slot: string
}

/** Retourwaarde van public.create_booking() */
export interface CreatedBooking {
  booking_id: string
  manage_token: string
  barber_id: string
  barber_name: string
  service_name: string
  starts_at: string
  ends_at: string
  price_cents: number
  currency: string
  shop_slug: string
  timezone: string
}

/** Retourwaarde van public.get_booking_by_token() */
export interface BookingDetail {
  id: string
  status: BookingStatus
  starts_at: string
  service_end_at: string
  service_name: string
  barber_name: string
  shop_name: string
  shop_slug: string
  shop_city: string | null
  shop_phone: string | null
  shop_timezone: string
  shop_address: string | null
  customer_name: string
  customer_email: string
  price_cents: number
  currency: string
  notes: string | null
  cancel_deadline: string
  can_modify: boolean
}
