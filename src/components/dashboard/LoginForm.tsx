'use client'

import { useActionState } from 'react'
import { useTranslations } from 'next-intl'
import { useFormStatus } from 'react-dom'

import { Alert, Button, Field, Input } from '@/components/ui'
import { signIn, type AuthState } from '@/actions/auth'

/**
 * Alleen inloggen — geen registratie.
 *
 * Accounts worden aangemaakt door de beheerder van de salon (of door de
 * platformbeheerder), niet door bezoekers zelf. Een registratieknop zou hier
 * alleen maar accounts opleveren die nergens bij horen.
 *
 * Let op: dit formulier weghalen sluit registratie niet echt af. Zet daarvoor
 * in Supabase onder Authentication → Sign In / Providers de optie
 * "Allow new users to sign up" uit. Zolang die aan staat kan iemand de
 * signup-endpoint rechtstreeks aanroepen.
 */
export default function LoginForm({
  nextPath,
  initialError,
}: {
  nextPath: string
  initialError?: string
}) {
  const t = useTranslations('auth')
  const [state, formAction] = useActionState<AuthState, FormData>(signIn, {
    error: initialError,
  })

  return (
    <form action={formAction} className="space-y-4">
      <input type="hidden" name="next" value={nextPath} />

      {state.error && <Alert>{state.error}</Alert>}

      <Field label={t('email')} required>
        <Input name="email" type="email" autoComplete="email" required />
      </Field>

      <Field label={t('password')} required>
        <Input name="password" type="password" autoComplete="current-password" required />
      </Field>

      <SubmitButton label={t('signIn')} wait={t('wait')} />

      <p className="pt-2 text-center text-sm text-ink-400">{t('noAccountHint')}</p>
    </form>
  )
}

function SubmitButton({ label, wait }: { label: string; wait: string }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? wait : label}
    </Button>
  )
}
