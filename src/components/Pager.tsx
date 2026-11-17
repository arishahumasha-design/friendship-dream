import Link from "next/link";
import { getI18n } from "@/lib/i18n/server";

/** "Previous / Page 2 of 5 / Next" links for long lists (nothing is shown when there is only one page). */
export async function Pager({
  page,
  totalPages,
  hrefFor,
}: {
  page: number;
  totalPages: number;
  hrefFor: (page: number) => string;
}) {
  if (totalPages <= 1) return null;
  const { t } = await getI18n();
  const link = "inline-flex h-10 items-center rounded-full border border-border bg-surface px-4 text-sm font-semibold hover:bg-accent-soft";
  return (
    <nav aria-label={t.common.pages} className="flex flex-wrap items-center justify-between gap-3 pt-2">
      {page > 1 ? (
        <Link href={hrefFor(page - 1)} className={link}>
          ← {t.common.pagePrev}
        </Link>
      ) : (
        <span />
      )}
      <span className="text-sm text-muted">
        {t.common.page} {page} / {totalPages}
      </span>
      {page < totalPages ? (
        <Link href={hrefFor(page + 1)} className={link}>
          {t.common.pageNext} →
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
