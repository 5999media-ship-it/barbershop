'use server'

import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

import { createClient } from '@/lib/supabase/server'
import { credentialsSchema } from '@/lib/validation'
import { siteUrl } from '@/lib/env'

export type AuthState = { error?: string; message?: string }

/**
 * Inloggen. Bewust generieke foutmelding: "e-mailadres of wachtwoord onjuist"
 * verklapt niet welke e-mailadressen een account hebben (user enumeration).
 */
export async function signIn(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = credentialsSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  })
  if (!parsed.success) {
    return { error: 'Vul een geldig e-mailadres en wachtwoord in.' }
  }

  const nextPath = String(formData.get('next') ?? '/dashboard')
  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword(parsed.data)

  if (error) {
    return { error: 'E-mailadres of wachtwoord onjuist.' }
  }

  revalidatePath('/', 'layout')
  redirect(nextPath.startsWith('/') ? nextPath : '/dashboard')
}

export async function signUp(_prev: AuthState, formData: FormData): Promise<AuthState> {
  const parsed = credentialsSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  })
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Controleer je gegevens.' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signUp({
    ...parsed.data,
    options: {
      data: { full_name: String(formData.get('full_name') ?? '').trim() || null },
      emailRedirectTo: `${siteUrl()}/dashboard`,
    },
  })

  if (error) {
    return { error: 'Aanmelden lukte niet. Bestaat er al een account met dit adres?' }
  }

  return {
    message:
      'Check je mailbox: we hebben een bevestigingslink gestuurd. Daarna kun je inloggen.',
  }
}

export async function signOut() {
  const supabase = await createClient()
  await supabase.auth.signOut()
  revalidatePath('/', 'layout')
  redirect('/login')
}
