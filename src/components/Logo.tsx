/** FD monogram: white F and D on an emerald circle with a small gold spark. */
export function Logo({ size = 40, className }: { size?: number; className?: string }) {
  return (
    <svg
      viewBox="0 0 140 140"
      width={size}
      height={size}
      className={className}
      role="img"
      aria-label="Friendship Dream logo"
    >
      <circle cx="70" cy="70" r="68" fill="#0B7A5A" />
      <g
        transform="translate(0 10)"
        fill="none"
        stroke="#FFFFFF"
        strokeWidth="12"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M34 90V32H56" />
        <path d="M34 60H52" />
        <path d="M72 32H78A28 28 0 0 1 78 88H72Z" />
      </g>
      <path
        d="M70 14L72.5 19.5L78 22L72.5 24.5L70 30L67.5 24.5L62 22L67.5 19.5Z"
        fill="#F5B83D"
      />
    </svg>
  );
}
