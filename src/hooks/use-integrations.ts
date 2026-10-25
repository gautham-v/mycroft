"use client";
/**
 * "Send to" integration state, fetched once per page load and shared by every subscriber.
 *
 *   const integrations = useIntegrations();   // null until the first fetch lands
 *   getIntegrations();                        // same, outside React
 *   setIntegrations(next);                    // after Settings saves (PUT returns the new state)
 *   refreshIntegrations();                    // refetch, e.g. if another tab may have changed it
 */
import { useSyncExternalStore } from "react";
import type { IntegrationsResponse, SendTarget } from "@/lib/types";

let current: IntegrationsResponse | null = null;
let inflight: Promise<void> | null = null;
const listeners = new Set<() => void>();

function emit() {
  for (const l of listeners) l();
}

/** Current state outside React (null until the first fetch lands). */
export function getIntegrations(): IntegrationsResponse | null {
  return current;
}

export function setIntegrations(next: IntegrationsResponse) {
  current = next;
  emit();
}

export function refreshIntegrations(): Promise<void> {
  inflight ??= fetch("/api/integrations", { cache: "no-store" })
    .then(async (r) => {
      if (r.ok) setIntegrations((await r.json()) as IntegrationsResponse);
    })
    .catch(() => {
      /* offline: leave the last known state */
    })
    .finally(() => {
      inflight = null;
    });
  return inflight;
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  if (!current) void refreshIntegrations();
  return () => listeners.delete(cb);
}

export function useIntegrations(): IntegrationsResponse | null {
  return useSyncExternalStore(
    subscribe,
    () => current,
    () => null,
  );
}

export const TARGET_LABEL: Record<SendTarget, string> = { readwise: "Readwise", webhook: "Webhook" };

/** Targets with a saved configuration, in menu order. */
export function configuredTargets(i: IntegrationsResponse | null): SendTarget[] {
  if (!i) return [];
  return (["readwise", "webhook"] as const).filter((t) => i[t].configured);
}
