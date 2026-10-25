"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import type {
  Folder,
  Item,
  ItemsResponse,
  PatchItemBody,
  ReorderSourcesBody,
  Source,
  SourcesResponse,
  Stats,
  View,
} from "@/lib/types";

export interface ItemsQuery {
  view: View;
  source: number | null;
  folder: number | null;
  /** Search text (already trimmed); "" or omitted = no search. */
  q?: string;
}

export function itemsQueryString(q: ItemsQuery, cursor?: string | null): string {
  const p = new URLSearchParams();
  p.set("view", q.view);
  if (q.source != null) p.set("source", String(q.source));
  if (q.folder != null) p.set("folder", String(q.folder));
  if (q.q) p.set("q", q.q);
  if (cursor) p.set("cursor", cursor);
  p.set("limit", "50");
  return p.toString();
}

async function getJSON<T>(url: string): Promise<T> {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return (await res.json()) as T;
}

export function useItems(q: ItemsQuery, enabled = true) {
  const [items, setItems] = useState<Item[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const key = itemsQueryString(q);
  const reqId = useRef(0);
  // The query `nextCursor` belongs to. After the query changes, the old cursor stays in state until
  // the reload lands; paging the new query from it would append the wrong rows.
  const cursorKey = useRef<string | null>(null);

  const reload = useCallback(async () => {
    const id = ++reqId.current;
    setLoading(true);
    try {
      const data = await getJSON<ItemsResponse>(`/api/items?${key}`);
      if (id !== reqId.current) return;
      setItems(data.items);
      setNextCursor(data.nextCursor);
      cursorKey.current = key;
      setError(null);
    } catch (e) {
      if (id === reqId.current) setError(e instanceof Error ? e.message : "Failed to load");
    } finally {
      if (id === reqId.current) setLoading(false);
    }
  }, [key]);

  const loadMore = useCallback(async () => {
    if (!nextCursor || loadingMore || cursorKey.current !== key) return;
    const id = reqId.current;
    setLoadingMore(true);
    try {
      const p = new URLSearchParams(key);
      p.set("cursor", nextCursor);
      const data = await getJSON<ItemsResponse>(`/api/items?${p}`);
      if (id !== reqId.current) return;
      setItems((prev) => {
        const seen = new Set(prev.map((i) => i.id));
        return [...prev, ...data.items.filter((i) => !seen.has(i.id))];
      });
      setNextCursor(data.nextCursor);
    } catch {
      /* keep cursor; sentinel will retry */
    } finally {
      setLoadingMore(false);
    }
  }, [key, nextCursor, loadingMore]);

  useEffect(() => {
    if (!enabled) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload();
  }, [reload, enabled]);

  const patchLocal = useCallback((id: number, patch: Partial<Item>) => {
    setItems((prev) => prev.map((i) => (i.id === id ? { ...i, ...patch } : i)));
  }, []);

  return { items, setItems, nextCursor, loading, loadingMore, error, reload, loadMore, patchLocal };
}

export function useSources() {
  const [sources, setSources] = useState<Source[]>([]);
  const [folders, setFolders] = useState<Folder[]>([]);
  const reload = useCallback(async () => {
    try {
      const data = await getJSON<SourcesResponse>("/api/sources");
      setSources(data.sources);
      setFolders(data.folders ?? []);
    } catch {
      /* offline */
    }
  }, []);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload();
  }, [reload]);
  return { sources, folders, setSources, setFolders, reload };
}

async function send<T>(url: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: body === undefined ? undefined : { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    const b = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(b?.error || `${method} ${res.status}`);
  }
  return (await res.json()) as T;
}

export const reorderSources = (order: ReorderSourcesBody["order"]) => send<{ ok: true }>("/api/sources", "PATCH", { order });
export const moveSource = (id: number, folder_id: number | null) => send<{ source: Source }>(`/api/sources/${id}`, "PATCH", { folder_id });
export const createFolder = (title: string) => send<{ folder: Folder }>("/api/folders", "POST", { title });
export const renameFolder = (id: number, title: string) => send<{ folder: Folder }>(`/api/folders/${id}`, "PATCH", { title });
export const deleteFolder = (id: number) => send<{ ok: true }>(`/api/folders/${id}`, "DELETE");
export const reorderFolders = (order: number[]) => send<{ ok: true }>("/api/folders", "PATCH", { order });

export function useStats() {
  const [stats, setStats] = useState<Stats | null>(null);
  const reload = useCallback(async () => {
    try {
      setStats(await getJSON<Stats>("/api/stats"));
    } catch {
      /* offline */
    }
  }, []);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload();
  }, [reload]);
  return { stats, setStats, reload };
}

export async function patchItem(id: number, body: PatchItemBody) {
  const res = await fetch(`/api/items/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`PATCH ${res.status}`);
}
