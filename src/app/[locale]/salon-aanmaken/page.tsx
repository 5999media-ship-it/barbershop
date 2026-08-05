import type { Metadata } from 'next'
import { redirect } from 'next/navigation'

import { Card } from '@/components/ui'
import { Link } from '@/i18n/navigation'
import { createClient } from '@/lib/supabase/server'
import { signOut } from '@/actions/auth'

export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Nog geen salon',
  robots: { index: false, follow: false },
}

/**
 * Landingspagina voor iemand die is ingelogd maar (nog) aan geen enkele salon
 * gekoppeld is.
 *
 * Salons worden uitsluitend door de platformbeheerder aangemaakt. Deze pagina
 * legt dat uit in plaats van een formulier te tonen dat toch geweigerd wordt —
 * een knop die altijd faalt is erger dan geen knop.
 */
export default async function NoShopPage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) redirect('/login')

  const { data: profile } = await supabase
    .from('profiles')
    .select('is_platform_admin')
    .eq('id', user.id)
    .maybeSingle<{ is_platform_admin: boolean }>()

  // De beheerder hoort hier niet: die maakt salons aan in het platformscherm.
  if (profile?.is_platform_admin) redirect('/dashboard/platform')

  return (
    <main className="mx-auto max-w-md px-5 py-20">
      <h1 className="text-3xl font-semibold tracking-tight">Je account staat klaar</h1>

      <Card className="mt-6 space-y-3 text-[15px] leading-relaxed text-ink-300">
        <p>
          Je bent ingelogd als <span className="text-ink-100">{user.email}</span>, maar je
          account is nog niet aan een salon gekoppeld.
        </p>
        <p>
          Laat de beheerder van je salon weten met welk e-mailadres je bent ingelogd. Zodra
          hij je koppelt, zie je hier je agenda, je werktijden en je eigen profiel.
        </p>
      </Card>

      <div className="mt-6 flex items-center gap-4 text-sm">
        <Link href="/" className="text-brass-300 hover:underline">
          Naar de website
        </Link>
        <form action={signOut}>
          <button type="submit" className="text-ink-400 hover:text-ink-100">
            Uitloggen
          </button>
        </form>
      </div>
    </main>
  )
}
