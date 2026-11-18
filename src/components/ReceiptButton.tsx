"use client";

import { useState } from "react";
import { signReceipt, type SignResult } from "@/app/actions/files";
import { useI18n } from "./I18nProvider";
import { ImageViewer } from "./ImageViewer";

/** "View receipt" link: fetches a FRESH 60-second signed URL on click. PDFs open in a new tab. */
export function ReceiptButton({
  depositId,
  sign,
  isPdf,
  label,
}: {
  /** a deposit id (default way to get the link) ... */
  depositId?: string;
  /** ... or any other server action that returns a fresh signed URL (e.g. an expense receipt) */
  sign?: () => Promise<SignResult>;
  isPdf: boolean;
  label: string;
}) {
  const { t } = useI18n();
  const [url, setUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  async function open() {
    setFailed(false);
    const tab = isPdf ? window.open("about:blank", "_blank") : null;
    setBusy(true);
    const res = sign ? await sign() : await signReceipt(depositId ?? "");
    setBusy(false);
    if ("error" in res) {
      tab?.close();
      setFailed(true);
      return;
    }
    if (tab) {
      tab.opener = null;
      tab.location.href = res.url;
    } else setUrl(res.url);
  }

  return (
    <>
      <button
        type="button"
        onClick={open}
        disabled={busy}
        className="text-sm font-semibold text-accent hover:underline disabled:opacity-60"
      >
        {busy ? t.common.loading : label}
      </button>
      {failed && <span className="ml-2 text-xs text-danger">{t.profile.viewFailed}</span>}
      {url && <ImageViewer url={url} label={label} onClose={() => setUrl(null)} />}
    </>
  );
}
