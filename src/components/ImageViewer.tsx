"use client";

import { useCallback, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useI18n } from "./I18nProvider";
import { cn } from "./ui";

const MIN = 1;
const MAX = 4;
const STEP = 0.5;

/**
 * Full-screen image viewer (modal) used everywhere a picture can be opened large.
 *  - the whole picture is shown inside the screen (object-contain);
 *  - zoom in / out / fit buttons (also + and - keys, double-click on the picture);
 *    a zoomed or big picture scrolls; on phones pinch-zoom works too;
 *  - Close button in the corner, Esc, or a click outside the picture closes it.
 * It only shows the URL it is given: signed-URL logic stays with the caller.
 */
export function ImageViewer({ url, label, onClose }: { url: string; label: string; onClose: () => void }) {
  const { t } = useI18n();
  const [scale, setScale] = useState(MIN);

  const zoomIn = useCallback(() => setScale((s) => Math.min(MAX, s + STEP)), []);
  const zoomOut = useCallback(() => setScale((s) => Math.max(MIN, s - STEP)), []);
  const fit = useCallback(() => setScale(MIN), []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      else if (e.key === "+" || e.key === "=") zoomIn();
      else if (e.key === "-" || e.key === "_") zoomOut();
      else if (e.key === "0") fit();
    };
    window.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [onClose, zoomIn, zoomOut, fit]);

  const zoomed = scale > MIN;

  // Portal to <body>: blurred parent cards would otherwise trap a fixed overlay.
  return createPortal(
    <div role="dialog" aria-modal="true" aria-label={label} className="fixed inset-0 z-50 flex flex-col bg-black/90 text-white">
      <div className="flex items-center gap-2 p-3 sm:p-4">
        <p className="min-w-0 flex-1 truncate text-sm font-semibold">{label}</p>
        <div className="flex items-center gap-1.5">
          <ToolButton label={t.profile.zoomOut} onClick={zoomOut} disabled={scale <= MIN}>
            −
          </ToolButton>
          <button
            type="button"
            onClick={fit}
            disabled={!zoomed}
            aria-label={t.profile.zoomFit}
            className="hidden h-10 min-w-14 items-center justify-center rounded-full bg-white/15 px-3 text-sm font-semibold tabular-nums hover:bg-white/25 disabled:opacity-60 sm:inline-flex"
          >
            {Math.round(scale * 100)}%
          </button>
          <ToolButton label={t.profile.zoomIn} onClick={zoomIn} disabled={scale >= MAX}>
            +
          </ToolButton>
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            className="hidden h-10 items-center rounded-full bg-white/15 px-4 text-sm font-semibold hover:bg-white/25 sm:inline-flex"
          >
            {t.profile.openNewTab}
          </a>
          <button
            type="button"
            onClick={onClose}
            autoFocus
            className="inline-flex h-10 items-center rounded-full bg-white px-4 text-sm font-semibold text-black hover:bg-white/85"
          >
            {t.profile.close}
          </button>
        </div>
      </div>

      {/* Scroll area. A click on the empty space around the picture closes the viewer. */}
      <div
        className="flex min-h-0 flex-1 overflow-auto p-3 sm:p-4"
        style={{ touchAction: "pan-x pan-y pinch-zoom" }}
        onClick={(e) => e.target === e.currentTarget && onClose()}
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- private signed URL, must not go through the image optimizer */}
        <img
          src={url}
          alt={label}
          draggable={false}
          onDoubleClick={() => setScale((s) => (s > MIN ? MIN : 2))}
          style={zoomed ? { width: `${scale * 100}%`, maxWidth: "none" } : undefined}
          className={cn(
            "m-auto rounded-lg bg-white shadow-2xl",
            zoomed ? "h-auto shrink-0 cursor-zoom-out" : "max-h-full max-w-full cursor-zoom-in object-contain",
          )}
        />
      </div>
    </div>,
    document.body,
  );
}

function ToolButton({ label, onClick, disabled, children }: { label: string; onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      className="inline-flex size-10 items-center justify-center rounded-full bg-white/15 text-xl font-semibold leading-none hover:bg-white/25 disabled:opacity-40"
    >
      {children}
    </button>
  );
}

/**
 * A member photo that opens in the viewer when clicked (round, like <Avatar>).
 * Only for places where the photo is NOT inside a link.
 */
export function ZoomableAvatar({ url, name, size }: { url: string; name: string; size: number }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label={`${t.profile.view}: ${name}`}
        style={{ width: size, height: size }}
        className="shrink-0 rounded-full outline-offset-2 focus-visible:outline-2 focus-visible:outline-accent"
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- private signed URL */}
        <img
          src={url}
          alt=""
          width={size}
          height={size}
          style={{ width: size, height: size }}
          className="rounded-full object-cover ring-2 ring-border transition hover:ring-accent"
        />
      </button>
      {open && <ImageViewer url={url} label={name} onClose={() => setOpen(false)} />}
    </>
  );
}
