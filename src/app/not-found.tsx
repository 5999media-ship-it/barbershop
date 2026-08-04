import Link from 'next/link'
import { Button } from '@/components/ui'

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-[70vh] max-w-md flex-col items-center justify-center px-5 text-center">
      <p className="text-sm font-medium uppercase tracking-[0.2em] text-brass-400">404</p>
      <h1 className="mt-3 text-3xl font-semibold">Deze pagina bestaat niet</h1>
      <p className="mt-3 text-ink-300">
        Misschien is de salon verhuisd of is de link verouderd.
      </p>
      <Link href="/" className="mt-7">
        <Button>Terug naar het overzicht</Button>
      </Link>
    </main>
  )
}
