import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, TextareaHTMLAttributes } from 'react'

export function cn(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(' ')
}

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'ghost' | 'danger' | 'subtle'
  size?: 'sm' | 'md' | 'lg'
}

export function Button({
  variant = 'primary',
  size = 'md',
  className,
  ...props
}: ButtonProps) {
  const variants = {
    primary: 'bg-brass-500 text-ink-950 hover:bg-brass-400 disabled:bg-ink-700 disabled:text-ink-400',
    ghost: 'border border-ink-600 text-ink-100 hover:border-brass-500 hover:text-brass-300',
    subtle: 'bg-ink-800 text-ink-100 hover:bg-ink-700',
    danger: 'border border-danger-500/50 text-danger-500 hover:bg-danger-500/10',
  }
  const sizes = { sm: 'h-9 px-3 text-sm', md: 'h-11 px-5 text-sm', lg: 'h-13 px-7 text-base' }

  return (
    <button
      className={cn(
        'btn-base disabled:cursor-not-allowed active:scale-[0.99]',
        variants[variant],
        sizes[size],
        className,
      )}
      {...props}
    />
  )
}

export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('card p-5', className)}>{children}</div>
}

export function Field({
  label,
  hint,
  error,
  children,
  required,
}: {
  label: string
  hint?: string
  error?: string
  children: ReactNode
  required?: boolean
}) {
  return (
    <label className="block">
      <span className="mb-1.5 flex items-baseline gap-1.5 text-sm font-medium text-ink-100">
        {label}
        {required && <span className="text-brass-400">*</span>}
        {hint && <span className="text-xs font-normal text-ink-400">{hint}</span>}
      </span>
      {children}
      {error && (
        <span role="alert" className="mt-1 block text-xs text-danger-500">
          {error}
        </span>
      )}
    </label>
  )
}

const inputBase =
  'w-full rounded-[10px] border border-ink-600 bg-ink-850 px-3.5 py-2.5 text-[15px] text-ink-100 placeholder:text-ink-400 focus:border-brass-500 focus:outline-none'

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return <input className={cn(inputBase, className)} {...props} />
}

export function Textarea({ className, ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={cn(inputBase, 'min-h-24 resize-y', className)} {...props} />
}

export function Badge({
  children,
  tone = 'neutral',
}: {
  children: ReactNode
  tone?: 'neutral' | 'success' | 'danger' | 'brass'
}) {
  const tones = {
    neutral: 'bg-ink-800 text-ink-300 border-ink-700',
    success: 'bg-success-500/10 text-success-500 border-success-500/30',
    danger: 'bg-danger-500/10 text-danger-500 border-danger-500/30',
    brass: 'bg-brass-500/10 text-brass-300 border-brass-500/30',
  }
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium',
        tones[tone],
      )}
    >
      {children}
    </span>
  )
}

export function Alert({
  children,
  tone = 'danger',
}: {
  children: ReactNode
  tone?: 'danger' | 'success' | 'info'
}) {
  const tones = {
    danger: 'border-danger-500/40 bg-danger-500/10 text-danger-500',
    success: 'border-success-500/40 bg-success-500/10 text-success-500',
    info: 'border-ink-600 bg-ink-850 text-ink-300',
  }
  return (
    <div role="alert" className={cn('rounded-[10px] border px-4 py-3 text-sm', tones[tone])}>
      {children}
    </div>
  )
}

export function Spinner({ label = 'Bezig…' }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-sm text-ink-400">
      <span
        aria-hidden
        className="h-4 w-4 animate-spin rounded-full border-2 border-ink-600 border-t-brass-400"
      />
      {label}
    </span>
  )
}
