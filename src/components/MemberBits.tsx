import type { MemberStatus } from "@/lib/auth";

/** Chip color for a member status. */
export const statusTone = (s: MemberStatus): "accent" | "gold" | "danger" | "neutral" =>
  s === "active" ? "accent" : s === "pending" ? "gold" : s === "suspended" ? "danger" : "neutral";

/** Round member photo, or the first letter of the name when there is no photo. */
export function Avatar({ url, name, size = 48 }: { url?: string | null; name: string; size?: number }) {
  const initial = name.trim().charAt(0).toUpperCase() || "?";
  return url ? (
    // eslint-disable-next-line @next/next/no-img-element -- private signed URL
    <img
      src={url}
      alt=""
      width={size}
      height={size}
      style={{ width: size, height: size }}
      className="shrink-0 rounded-full object-cover ring-2 ring-border"
    />
  ) : (
    <span
      aria-hidden
      style={{ width: size, height: size }}
      className="grid shrink-0 place-items-center rounded-full bg-accent-soft text-lg font-bold text-accent"
    >
      {initial}
    </span>
  );
}

/** Chip color for a deposit review status. */
export const depositTone = (s: "pending" | "approved" | "rejected"): "accent" | "gold" | "danger" =>
  s === "approved" ? "accent" : s === "pending" ? "gold" : "danger";
