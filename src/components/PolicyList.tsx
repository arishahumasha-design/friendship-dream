"use client";

import { useMemo, useState } from "react";
import type { Policy } from "@/lib/content";
import { formatDay } from "@/lib/format";
import { useI18n } from "./I18nProvider";
import { Card, Field } from "./ui";

/** All policies in their saved order, with a search box (title and text). The text is shown exactly as stored. */
export function PolicyList({ policies }: { policies: Policy[] }) {
  const { t, lang } = useI18n();
  const [q, setQ] = useState("");

  const shown = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return policies
      .map((p, i) => ({ p, number: i + 1 }))
      .filter(({ p }) => !needle || p.title.toLowerCase().includes(needle) || p.body.toLowerCase().includes(needle));
  }, [policies, q]);

  return (
    <div className="space-y-4">
      <Field
        id="policy-search"
        type="search"
        label={t.content.search}
        placeholder={t.content.searchPlaceholder}
        value={q}
        onChange={(e) => setQ(e.target.value)}
        autoComplete="off"
      />
      <p className="text-xs text-muted" aria-live="polite">
        {shown.length} / {policies.length}
      </p>
      {shown.length === 0 ? (
        <Card className="text-center text-sm text-muted">{t.content.noResults}</Card>
      ) : (
        <ol className="space-y-3">
          {shown.map(({ p, number }) => (
            <li key={p.id}>
              <Card className="space-y-2 p-5 sm:p-6">
                <div className="flex items-start gap-3">
                  <span className="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-accent-soft text-sm font-bold text-accent">
                    {number}
                  </span>
                  <div className="min-w-0">
                    <h2 className="text-lg font-bold leading-snug">{p.title}</h2>
                    <p className="text-xs text-muted">
                      {t.content.effectiveFrom} {formatDay(p.effectiveFrom, lang)}
                    </p>
                  </div>
                </div>
                <p className="whitespace-pre-line break-words text-[0.95rem] leading-relaxed">{p.body}</p>
              </Card>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
