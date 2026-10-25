"use client";
import { useEffect, useRef, useState } from "react";
import type { ApiError, Item, SendTarget } from "@/lib/types";
import { configuredTargets, getIntegrations, refreshIntegrations, TARGET_LABEL, useIntegrations } from "@/hooks/use-integrations";
import { CheckIcon, SendIcon } from "./icons";

// Same look as the reader's ActionButton (reader.tsx), plus menu-button ARIA.
const BUTTON =
  "inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--ink)] disabled:opacity-60 lg:h-[30px] lg:w-[30px]";

const MENU_LABEL: Record<SendTarget, string> = { readwise: "Readwise Reader", webhook: "Webhook" };

type Status = { kind: "idle" } | { kind: "sending" } | { kind: "sent"; target: SendTarget } | { kind: "error"; message: string };

async function send(itemId: number, target: SendTarget): Promise<void> {
  const res = await fetch(`/api/items/${itemId}/send`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ target }),
  });
  if (res.ok) return;
  const body = (await res.json().catch(() => null)) as ApiError | null;
  throw new Error(body?.error || `Request failed (${res.status})`);
}

/**
 * Reader action: sends the item to Readwise Reader or the webhook. One target configured: sends
 * straight away. Both: a two-item menu. None: opens Settings on the Integrations tab.
 */
export function SendToButton({ item, onSetup }: { item: Item; onSetup: () => void }) {
  const integrations = useIntegrations();
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const [menuOpen, setMenuOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => () => clearTimeout(timer.current), []);

  // Menu: close on outside pointer or Escape (kept from the app's global Escape handling).
  useEffect(() => {
    if (!menuOpen) return;
    const onDown = (e: PointerEvent) => {
      if (!wrap.current?.contains(e.target as Node)) setMenuOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      setMenuOpen(false);
      wrap.current?.querySelector<HTMLButtonElement>("button")?.focus();
    };
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey, true);
    wrap.current?.querySelector<HTMLButtonElement>('[role="menuitem"]')?.focus();
    return () => {
      document.removeEventListener("pointerdown", onDown, true);
      document.removeEventListener("keydown", onKey, true);
    };
  }, [menuOpen]);

  const flash = (s: Status, ms: number) => {
    clearTimeout(timer.current);
    setStatus(s);
    timer.current = setTimeout(() => setStatus({ kind: "idle" }), ms);
  };

  const sendTo = async (target: SendTarget) => {
    setMenuOpen(false);
    clearTimeout(timer.current);
    setStatus({ kind: "sending" });
    try {
      await send(item.id, target);
      flash({ kind: "sent", target }, 1800);
    } catch (e) {
      flash({ kind: "error", message: e instanceof Error ? e.message : "Could not send" }, 5000);
    }
  };

  const onClick = async () => {
    if (status.kind === "sending") return;
    // The first click can beat the initial fetch; wait for it rather than guessing.
    if (!getIntegrations()) await refreshIntegrations();
    const targets = configuredTargets(getIntegrations());
    if (targets.length === 0) onSetup();
    else if (targets.length === 1) void sendTo(targets[0]);
    else {
      // A leftover error bubble would sit under the menu.
      clearTimeout(timer.current);
      setStatus({ kind: "idle" });
      setMenuOpen((v) => !v);
    }
  };

  const targets = configuredTargets(integrations);
  const hasMenu = targets.length > 1;
  const label =
    status.kind === "sent"
      ? `Sent to ${TARGET_LABEL[status.target]}`
      : status.kind === "sending"
        ? "Sending…"
        : targets.length === 1
          ? `Send to ${TARGET_LABEL[targets[0]]}`
          : targets.length === 0 && integrations
            ? "Send to… (set up in Settings)"
            : "Send to…";

  return (
    <div ref={wrap} className="relative">
      <button
        type="button"
        onClick={() => void onClick()}
        aria-label={label}
        title={label}
        aria-haspopup={hasMenu ? "menu" : undefined}
        aria-expanded={hasMenu ? menuOpen : undefined}
        aria-busy={status.kind === "sending" || undefined}
        className={BUTTON}
      >
        {status.kind === "sent" ? (
          <CheckIcon size={17} className="text-[var(--accent)]" />
        ) : (
          <SendIcon size={17} className={status.kind === "sending" ? "animate-pulse" : ""} />
        )}
      </button>

      {/* Announces the outcome; the error is also shown, since a title alone is easy to miss. */}
      <span role="status" className="sr-only">
        {status.kind === "sent" ? label : ""}
      </span>
      {status.kind === "error" && (
        <p
          role="alert"
          className="absolute right-0 top-full z-30 mt-1 w-max max-w-[min(280px,80vw)] rounded-lg border border-[var(--hairline)] bg-[var(--surface)] px-3 py-2 text-[12.5px] leading-snug text-[var(--danger)] shadow-xl"
        >
          {status.message}
        </p>
      )}

      {menuOpen && (
        <div
          role="menu"
          aria-label="Send to"
          className="absolute right-0 top-full z-30 mt-1 min-w-[160px] rounded-lg border border-[var(--hairline)] bg-[var(--surface)] p-1 text-[14px] shadow-xl lg:text-[13px]"
        >
          {targets.map((t) => (
            <button
              key={t}
              type="button"
              role="menuitem"
              onClick={() => void sendTo(t)}
              onKeyDown={(e) => {
                if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
                e.preventDefault();
                const sib = e.key === "ArrowDown" ? e.currentTarget.nextElementSibling : e.currentTarget.previousElementSibling;
                (sib as HTMLElement | null)?.focus();
              }}
              className="flex h-11 w-full items-center rounded-[5px] px-2.5 text-left text-[var(--ink)] hover:bg-[var(--hover)] focus:bg-[var(--hover)] focus:outline-none lg:h-[28px] lg:px-2"
            >
              {MENU_LABEL[t]}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
