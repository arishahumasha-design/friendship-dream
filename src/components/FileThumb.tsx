"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { signFile, type SignResult } from "@/app/actions/files";
import type { FileRef } from "@/lib/members";
import { useI18n } from "./I18nProvider";
import { cn } from "./ui";

/**
 * Small preview of a private file. Clicking opens it large, using a FRESH
 * 60-second signed URL from the server (the thumbnail link may have expired).
 */
export function FileThumb({
  memberId,
  file,
  label,
  localUrl,
  className,
  sign,
}: {
  /** needed for member documents; not needed when a custom `sign` is given */
  memberId?: string;
  /** custom way to get a fresh signed URL (e.g. for a deposit receipt) */
  sign?: () => Promise<SignResult>;
  file: FileRef | null;
  label: string;
  /** a just-picked file shown before the page reloads */
  localUrl?: string | null;
  className?: string;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  const thumb = localUrl ?? (file && !file.isPdf ? file.url : null);
  const isPdf = !localUrl && file?.isPdf;

  async function openLarge() {
    if (!file && !localUrl) return;
    setFailed(false);
    if (localUrl) {
      setOpen(localUrl);
      return;
    }
    // Open the tab now (popup blockers allow it), then point it at the signed URL.
    const pdfTab = isPdf ? window.open("about:blank", "_blank") : null;
    setBusy(true);
    const res = sign ? await sign() : await signFile(memberId ?? "", file!.id);
    setBusy(false);
    if ("error" in res) {
      pdfTab?.close();
      setFailed(true);
      return;
    }
    if (pdfTab) {
      pdfTab.opener = null;
      pdfTab.location.href = res.url;
    } else setOpen(res.url);
  }

  return (
    <>
      <button
        type="button"
        onClick={openLarge}
        disabled={(!file && !localUrl) || busy}
        aria-label={`${t.profile.view}: ${label}`}
        className={cn(
          "group relative grid aspect-[4/3] w-full place-items-center overflow-hidden rounded-2xl border border-border bg-surface-strong text-muted transition enabled:hover:border-accent disabled:cursor-default",
          className,
        )}
      >
        {thumb ? (
          // eslint-disable-next-line @next/next/no-img-element -- private signed URL, must not go through the image optimizer
          <img src={thumb} alt={label} className="size-full bg-white object-contain" />
        ) : isPdf ? (
          <span className="flex flex-col items-center gap-1 text-sm font-semibold text-accent">
            <PdfIcon />
            {t.profile.openPdf}
          </span>
        ) : (
          <span className="flex flex-col items-center gap-1 px-2 text-center text-xs">
            <ImageIcon />
            {t.profile.notUploaded}
          </span>
        )}
        {busy && (
          <span className="absolute inset-0 grid place-items-center bg-bg/60 text-xs font-medium text-fg">
            {t.common.loading}
          </span>
        )}
      </button>
      {failed && <p className="mt-1 text-xs text-danger">{t.profile.viewFailed}</p>}
      {open && <Lightbox url={open} label={label} onClose={() => setOpen(null)} />}
    </>
  );
}

export function Lightbox({ url, label, onClose }: { url: string; label: string; onClose: () => void }) {
  const { t } = useI18n();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [onClose]);

  // Portal to <body>: blurred parent cards would otherwise trap a fixed overlay.
  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label={label}
      className="fixed inset-0 z-50 flex flex-col bg-black/85 p-4 backdrop-blur-sm"
      onClick={onClose}
    >
      <div className="mx-auto flex w-full max-w-4xl items-center justify-between gap-3 pb-3 text-white">
        <p className="truncate text-sm font-semibold">{label}</p>
        <button
          type="button"
          onClick={onClose}
          autoFocus
          className="inline-flex h-10 items-center rounded-full bg-white/15 px-4 text-sm font-semibold hover:bg-white/25"
        >
          {t.profile.close}
        </button>
      </div>
      <div className="grid min-h-0 flex-1 place-items-center">
        {/* eslint-disable-next-line @next/next/no-img-element -- private signed URL */}
        <img
          src={url}
          alt={label}
          onClick={(e) => e.stopPropagation()}
          className="max-h-full max-w-full rounded-xl bg-white object-contain shadow-2xl"
        />
      </div>
    </div>,
    document.body,
  );
}

function ImageIcon() {
  return (
    <svg viewBox="0 0 24 24" className="size-6" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="3" y="4" width="18" height="16" rx="3" />
      <circle cx="9" cy="10" r="2" />
      <path d="m21 16-5-5-9 9" />
    </svg>
  );
}

function PdfIcon() {
  return (
    <svg viewBox="0 0 24 24" className="size-7" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
      <path d="M14 3v5h5M9 13h6M9 17h4" />
    </svg>
  );
}
