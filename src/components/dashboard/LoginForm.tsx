'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'

import { Alert, Button, Field, Input } from '@/components/ui'
import { signIn, signUp, type AuthState } from '@/actions/auth'

export default function LoginForm({
  nextPath,
  initialError,
}: {
  nextPath: string
  initialError?: string
}) {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin')
  const action = mode === 'signin' ? signIn : signUp
  const [state, formAction] = useActionState<AuthState, FormData>(action, {
    error: initialError,
  })

  return (
    <form action={formAction} className="space-y-4">
      <input type="hidden" name="next" value={nextPath} />

      {state.error && <Alert>{state.error}</Alert>}
      {state.message && <Alert tone="success">{state.message}</Alert>}

      {mode === 'signup' && (
        <Field label="Naam">
          <Input name="full_name" autoComplete="name" />
        </Field>
      )}

      <Field label="E-mail" required>
        <Input name="email" type="email" autoComplete="email" required />
      </Field>

      <Field
        label="Wachtwoord"
        hint={mode === 'signup' ? 'minimaal 10 tekens' : undefined}
        required
      >
        <Input
          name="password"
          type="password"
          autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
          required
          minLength={mode === 'signup' ? 10 : undefined}
        />
      </Field>

      <SubmitButton label={mode === 'signin' ? 'Inloggen' : 'Account aanmaken'} />

      <p className="pt-2 text-center text-sm text-ink-400">
        {mode === 'signin' ? 'Nog geen account?' : 'Al een account?'}{' '}
        <button
          type="button"
          onClick={() => setMode(mode === 'signin' ? 'signup' : 'signin')}
          className="text-brass-300 hover:underline"
        >
          {mode === 'signin' ? 'Salon aanmelden' : 'Inloggen'}
        </button>
      </p>
    </form>
  )
}

function SubmitButton({ label }: { label: string }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="lg" className="w-full" disabled={pending}>
      {pending ? 'Even geduld…' : label}
    </Button>
  )
}
