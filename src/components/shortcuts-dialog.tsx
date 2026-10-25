"use client";
import { useEffect, useRef } from "react";
import { SHORTCUTS } from "@/hooks/use-keyboard";
import { CloseIcon } from "./icons";

/** Keyboard shortcuts overlay, opened with "?" or from Settings → Appearance. Esc or "?" closes it. */
export function ShortcutsDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      onKeyDown={(e) => {
        // Esc closes natively; keep it from also reaching the app's global shortcuts.
        if (e.key === "Escape") e.stopPropagation();
        if (e.key === "?") {
          e.preventDefault();
          onClose();
        }
      }}
      // Clicking the backdrop (the dialog element itself, outside the panel) closes it.
      onClick={(e) => e.target === e.currentTarget && onClose()}
      aria-labelledby="shortcuts-title"
      className="m-auto w-[min(94vw,420px)] rounded-xl border border-[var(--hairline)] bg-[var(--surface)] p-0 text-[var(--body)] shadow-2xl backdrop:bg-black/30"
    >
      <div className="px-5 pb-5 pt-4">
        <h2 id="shortcuts-title" className="pr-10 text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)]">
          Keyboard shortcuts
        </h2>
        {SHORTCUTS.map((g) => (
          <section key={g.group} className="mt-4">
            <h3 className="pb-1 text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)]">{g.group}</h3>
            <dl>
              {g.items.map((s) => (
                <div key={s.label} className="flex items-center justify-between gap-3 border-t border-[var(--hairline)] py-1.5">
                  <dt className="text-[14px] text-[var(--ink)]">{s.label}</dt>
                  <dd className="flex shrink-0 items-center gap-1">
                    {s.keys.map((k, i) => (
                      <span key={k} className="flex items-center gap-1">
                        {i > 0 && s.sep && <span className="text-[11px] text-[var(--faint)]">{s.sep}</span>}
                        <kbd className="min-w-[22px] rounded-[5px] border border-[var(--hairline)] bg-[var(--code)] px-1.5 text-center font-sans text-[12px] leading-[20px] text-[var(--ink)]">
                          {k}
                        </kbd>
                      </span>
                    ))}
                  </dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>
      <button
        type="button"
        onClick={onClose}
        aria-label="Close keyboard shortcuts"
        className="absolute right-3 top-3 inline-flex h-[30px] w-[30px] items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)]"
      >
        <CloseIcon size={18} />
      </button>
    </dialog>
  );
}
