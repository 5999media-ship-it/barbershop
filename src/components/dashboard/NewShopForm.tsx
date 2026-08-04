'use client'

import { useActionState, useEffect } from 'react'
import { useRouter } from 'next/navigation'

import { Alert, Button, Field, Input } from '@/components/ui'
import { createShop, type ActionState } from '@/app/dashboard/actions'

export default function NewShopForm() {
  const router = useRouter()
  const [state, formAction, pending] = useActionState<ActionState, FormData>(createShop, {})

  useEffect(() => {
    if (state.message) router.push('/dashboard/settings')
  }, [state.message, router])

  return (
    <form action={formAction} className="space-y-4">
      {state.error && <Alert>{state.error}</Alert>}

      <Field label="Naam van de salon" required>
        <Input name="name" required maxLength={120} placeholder="Junique Fades" />
      </Field>
      <Field label="Plaats" required>
        <Input name="city" required maxLength={80} placeholder="Amsterdam" />
      </Field>

      <Button type="submit" size="lg" className="w-full" disabled={pending}>
        {pending ? 'Aanmaken…' : 'Salon aanmaken'}
      </Button>
    </form>
  )
}
