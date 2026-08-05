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

// signUp is bewust verwijderd: accounts worden door de beheerder aangemaakt
// (zie createStaffAccount in src/actions/dashboard.ts). Sluit registratie ook
// in Supabase af onder Authentication → Sign In / Providers.

export async function signOut() {
  const supabase = await createClient()
  await supabase.auth.signOut()
  revalidatePath('/', 'layout')
  redirect('/login')
}
