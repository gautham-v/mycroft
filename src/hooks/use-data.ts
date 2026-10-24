"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import type { Filter, Item, ItemsResponse, Source, SourcesResponse, Stats, View } from "@/lib/types";

export interface ItemsQuery {
  view: View;
  source: number | null;
  filter: Filter | null;
}

export function itemsQueryString(q: ItemsQuery, cursor?: string | null): string {
  const p = new URLSearchParams();
  p.set("view", q.view);
  if (q.source != null) p.set("source", String(q.source));
  if (q.filter) p.set("filter", q.filter);
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

  const reload = useCallback(async () => {
    const id = ++reqId.current;
    setLoading(true);
    try {
      const data = await getJSON<ItemsResponse>(`/api/items?${key}`);
      if (id !== reqId.current) return;
      setItems(data.items);
      setNextCursor(data.nextCursor);
      setError(null);
    } catch (e) {
      if (id === reqId.current) setError(e instanceof Error ? e.message : "Failed to load");
    } finally {
      if (id === reqId.current) setLoading(false);
    }
  }, [key]);

  const loadMore = useCallback(async () => {
    if (!nextCursor || loadingMore) return;
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
  const reload = useCallback(async () => {
    try {
      const data = await getJSON<SourcesResponse | Source[]>("/api/sources");
      setSources(Array.isArray(data) ? data : data.sources);
    } catch {
      /* offline */
    }
  }, []);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void reload();
  }, [reload]);
  return { sources, reload };
}

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

export async function patchItem(id: number, body: { is_read?: boolean; is_saved?: boolean }) {
  const res = await fetch(`/api/items/${id}`, {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`PATCH ${res.status}`);
}
