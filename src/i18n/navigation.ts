import { createNavigation } from 'next-intl/navigation'
import { routing } from './routing'

/**
 * Gebruik deze in plaats van `next/link` en `next/navigation`.
 * Ze houden automatisch de actieve taal in de URL vast.
 */
export const { Link, redirect, usePathname, useRouter, getPathname } =
  createNavigation(routing)
