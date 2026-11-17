/**
 * Only allow redirects to a page on OUR OWN site.
 * Rejects: other sites ("//evil.com", "https://evil.com"), backslash tricks ("/\evil.com"),
 * control characters (tab, newline, ...), and anything that does not stay on the same origin
 * when parsed like a browser would.
 */
export function safeNext(value: unknown, fallback = "/home"): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 2000) return fallback;
  if (!value.startsWith("/") || value.startsWith("//")) return fallback;
  if (/[\\\u0000-\u001f\u007f]/.test(value)) return fallback;
  try {
    if (new URL(value, "http://x").origin !== "http://x") return fallback;
  } catch {
    return fallback;
  }
  return value;
}
