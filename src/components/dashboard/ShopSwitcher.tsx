'use client'

import { useRouter } from 'next/navigation'
import { useTransition } from 'react'

import type { Shop } from '@/lib/supabase/database.types'

export default function ShopSwitcher({
  shops,
  activeId,
}: {
  shops: Shop[]
  activeId: string
}) {
  const router = useRouter()
  const [pending, startTransition] = useTransition()

  if (shops.length === 1) {
    return <span className="text-lg font-semibold">{shops[0]!.name}</span>
  }

  return (
    <select
      aria-label="Actieve salon"
      value={activeId}
      disabled={pending}
      onChange={(e) => {
        // Cookie voor één jaar; puur een voorkeur, geen autorisatie.
        // RLS bepaalt alsnog of deze gebruiker de shop mag zien.
        document.cookie = `bb_shop=${e.target.value}; path=/; max-age=31536000; samesite=lax`
        startTransition(() => router.refresh())
      }}
      className="rounded-[10px] border border-ink-600 bg-ink-850 px-3 py-2 text-lg font-semibold"
    >
      {shops.map((shop) => (
        <option key={shop.id} value={shop.id}>
          {shop.name}
        </option>
      ))}
    </select>
  )
}
