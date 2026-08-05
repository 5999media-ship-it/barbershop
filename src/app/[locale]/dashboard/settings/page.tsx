import { getDashboardContext } from '@/lib/dashboard'
import SettingsForm from '@/components/dashboard/SettingsForm'

export const dynamic = 'force-dynamic'

export default async function SettingsPage() {
  const ctx = await getDashboardContext()

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Instellingen</h1>
        <p className="mt-1 text-sm text-ink-400">
          Adresgegevens zijn niet alleen voor je klanten: Google gebruikt ze voor je positie
          in de lokale zoekresultaten. Vul ze precies zo in als op je Google-bedrijfsprofiel.
        </p>
      </header>

      <SettingsForm shop={ctx.shop} canManage={ctx.canManage} />
    </>
  )
}
