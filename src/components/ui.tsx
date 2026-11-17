import Link from "next/link";
import type { ComponentProps, ReactNode } from "react";

export function cn(...classes: (string | false | null | undefined)[]) {
  return classes.filter(Boolean).join(" ");
}

/** Glass-style card used across the app. */
export function Card({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      className={cn(
        "rounded-3xl border border-border bg-surface p-6 shadow-[0_10px_40px_-12px_rgb(16_32_26/0.18)] backdrop-blur-xl sm:p-8",
        className,
      )}
      {...props}
    />
  );
}

type Variant = "primary" | "secondary" | "ghost" | "danger";

const variants: Record<Variant, string> = {
  primary: "bg-accent text-accent-fg hover:brightness-110 shadow-sm",
  secondary: "border border-border bg-surface text-fg hover:bg-accent-soft backdrop-blur",
  ghost: "text-fg hover:bg-accent-soft",
  danger: "bg-danger text-white hover:brightness-110",
};

const buttonBase =
  "inline-flex h-11 items-center justify-center gap-2 whitespace-nowrap rounded-full px-5 text-sm font-semibold transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-60";

export function Button({
  variant = "primary",
  className,
  ...props
}: ComponentProps<"button"> & { variant?: Variant }) {
  return <button className={cn(buttonBase, variants[variant], className)} {...props} />;
}

export function ButtonLink({
  variant = "primary",
  className,
  ...props
}: ComponentProps<typeof Link> & { variant?: Variant }) {
  return <Link className={cn(buttonBase, variants[variant], className)} {...props} />;
}

export function Field({
  label,
  hint,
  id,
  ...props
}: ComponentProps<"input"> & { label: string; hint?: string; id: string }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-fg">
        {label}
      </label>
      <input
        id={id}
        className="block h-11 w-full rounded-2xl border border-border bg-surface-strong px-4 text-base text-fg placeholder:text-muted/70 focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/30"
        {...props}
      />
      {hint && <p className="text-xs text-muted">{hint}</p>}
    </div>
  );
}

export function Select({
  label,
  hint,
  id,
  children,
  ...props
}: ComponentProps<"select"> & { label: string; hint?: string; id: string }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-fg">
        {label}
      </label>
      <select
        id={id}
        className="block h-11 w-full rounded-2xl border border-border bg-surface-strong px-3 text-base text-fg focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/30"
        {...props}
      >
        {children}
      </select>
      {hint && <p className="text-xs text-muted">{hint}</p>}
    </div>
  );
}

export function TextArea({
  label,
  hint,
  id,
  ...props
}: ComponentProps<"textarea"> & { label: string; hint?: string; id: string }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-fg">
        {label}
      </label>
      <textarea
        id={id}
        rows={3}
        className="block w-full rounded-2xl border border-border bg-surface-strong px-4 py-3 text-base text-fg placeholder:text-muted/70 focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/30"
        {...props}
      />
      {hint && <p className="text-xs text-muted">{hint}</p>}
    </div>
  );
}

/** Small rounded label, e.g. a status. */
export function Chip({
  tone = "neutral",
  children,
}: {
  tone?: "neutral" | "accent" | "gold" | "danger";
  children: ReactNode;
}) {
  const tones = {
    neutral: "bg-fg/8 text-muted",
    accent: "bg-accent-soft text-accent",
    gold: "bg-gold/20 text-[#8a5a00] dark:text-gold",
    danger: "bg-danger-soft text-danger",
  };
  return (
    <span className={cn("inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold", tones[tone])}>
      {children}
    </span>
  );
}

export function Alert({
  tone = "error",
  children,
}: {
  tone?: "error" | "success";
  children: ReactNode;
}) {
  return (
    <p
      role={tone === "error" ? "alert" : "status"}
      className={cn(
        "rounded-2xl px-4 py-3 text-sm",
        tone === "error" ? "bg-danger-soft text-danger" : "bg-accent-soft text-accent",
      )}
    >
      {children}
    </p>
  );
}
