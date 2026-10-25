"use client";
import { useEffect, useRef, useState } from "react";
import { CloseIcon } from "./icons";

export function AddSourceDialog({ open, onClose, onAdded }: { open: boolean; onClose: () => void; onAdded: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!url.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch("/api/sources", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ url: url.trim() }),
      });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error || `Request failed (${res.status})`);
      }
      setUrl("");
      onAdded();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not add source");
    } finally {
      setBusy(false);
    }
  };

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      aria-labelledby="add-source-title"
      className="m-auto w-[min(92vw,420px)] rounded-xl border border-[var(--hairline)] bg-[var(--surface)] p-0 shadow-2xl text-[var(--body)] backdrop:bg-black/30"
    >
      <form onSubmit={submit} className="p-5">
        <div className="flex items-center justify-between">
          <h2 id="add-source-title" className="text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)]">
            Add source
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="inline-flex h-[30px] w-[30px] items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)]"
          >
            <CloseIcon size={18} />
          </button>
        </div>
        <label htmlFor="add-source-url" className="mt-3 block text-[13px] text-[var(--muted)]">
          Feed, site, or YouTube channel URL
        </label>
        <p className="mt-0.5 text-[12px] text-[var(--faint)]">No feed? A news or blog listing page is scraped for new posts.</p>
        <input
          id="add-source-url"
          type="url"
          inputMode="url"
          autoFocus
          required
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://example.com or youtube.com/@handle"
          className="mt-1.5 h-11 w-full rounded-lg border border-[var(--border)] bg-[var(--ground)] px-3 text-[15px] outline-none focus:border-[var(--accent)]"
        />
        {error && (
          <p role="alert" className="mt-2 text-[13px] text-[var(--danger)]">
            {error}
          </p>
        )}
        <div className="mt-4 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="h-10 rounded-lg border border-[var(--border)] px-4 text-[14px] font-medium text-[var(--ink)] hover:bg-[var(--hover)]"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={busy}
            className="h-10 rounded-lg bg-[var(--accent)] px-4 text-[14px] font-medium text-white disabled:opacity-60"
          >
            {busy ? "Adding..." : "Add"}
          </button>
        </div>
      </form>
    </dialog>
  );
}
