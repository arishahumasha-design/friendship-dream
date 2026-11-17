import Link from "next/link";

export type RingMember = { id: string; name: string; photoUrl: string | null };

/**
 * A ring of member photos slowly turning around a centre disc.
 * Pure CSS (see globals.css): pauses on hover/focus, stops with prefers-reduced-motion.
 * Photos are short-lived signed links (private bucket); members without a photo show initials.
 */
export function MemberRing({
  members,
  centerValue,
  centerLabel,
}: {
  members: RingMember[];
  centerValue: string;
  centerLabel: string;
}) {
  const shown = members.slice(0, 24);
  return (
    <div className="fd-ring" style={{ ["--n" as string]: Math.max(shown.length, 1) }}>
      <div className="fd-ring-center">
        <p className="text-4xl font-bold leading-none tracking-tight text-accent">{centerValue}</p>
        <p className="mt-1 text-xs font-medium text-muted">{centerLabel}</p>
      </div>
      <ul className="fd-ring-orbit">
        {shown.map((m, i) => (
          <li key={m.id} style={{ ["--i" as string]: i }}>
            <Link
              href={`/members/${m.id}`}
              title={m.name}
              aria-label={m.name}
              className="fd-ring-item rounded-full outline-offset-2 focus-visible:outline-2 focus-visible:outline-accent"
            >
              {m.photoUrl ? (
                // eslint-disable-next-line @next/next/no-img-element -- private signed URL
                <img
                  src={m.photoUrl}
                  alt=""
                  loading="eager"
                  className="size-full rounded-full bg-surface-strong object-cover ring-2 ring-border"
                />
              ) : (
                <span
                  aria-hidden
                  className="grid size-full place-items-center rounded-full bg-accent-soft text-sm font-bold text-accent ring-2 ring-border"
                >
                  {m.name.trim().charAt(0).toUpperCase() || "?"}
                </span>
              )}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
