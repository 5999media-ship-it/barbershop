'use client'

import { useEffect, useState } from 'react'
import { useTranslations } from 'next-intl'

import { THEME_COOKIE, type ThemeChoice } from '@/lib/theme-shared'

const OPTIONS: ThemeChoice[] = ['light', 'dark', 'system']

export default function ThemeToggle({ initial }: { initial: ThemeChoice }) {
  const t = useTranslations('theme')
  const [choice, setChoice] = useState<ThemeChoice>(initial)

  // Bij 'system' meebewegen als de gebruiker zijn systeeminstelling omzet
  // terwijl de pagina openstaat.
  useEffect(() => {
    if (choice !== 'system') return
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const apply = () => document.documentElement.classList.toggle('dark', mq.matches)
    apply()
    mq.addEventListener('change', apply)
    return () => mq.removeEventListener('change', apply)
  }, [choice])

  function pick(next: ThemeChoice) {
    setChoice(next)
    document.cookie = `${THEME_COOKIE}=${next}; path=/; max-age=31536000; samesite=lax`

    const dark =
      next === 'dark' ||
      (next === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches)
    document.documentElement.classList.toggle('dark', dark)
  }

  return (
    <div
      role="radiogroup"
      aria-label={t('label')}
      className="inline-flex rounded-full border border-ink-700 p-0.5"
    >
      {OPTIONS.map((option) => (
        <button
          key={option}
          role="radio"
          aria-checked={choice === option}
          onClick={() => pick(option)}
          className={`rounded-full px-2.5 py-1 text-xs transition ${
            choice === option
              ? 'bg-ink-800 text-ink-100'
              : 'text-ink-400 hover:text-ink-100'
          }`}
        >
          {t(option)}
        </button>
      ))}
    </div>
  )
}
