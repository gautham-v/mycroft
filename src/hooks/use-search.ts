"use client";
import { useCallback, useEffect, useRef, useState } from "react";

/** Typing pause before the query is committed to the URL (and the list refetches). */
export const SEARCH_DEBOUNCE_MS = 250;

/** Focuses whichever search input is on screen (phone and desktop headers each render one). */
function focusVisibleInput() {
  requestAnimationFrame(() => {
    const inputs = document.querySelectorAll<HTMLInputElement>("input[data-search]");
    for (const el of inputs) {
      if (el.getClientRects().length > 0) {
        el.focus();
        el.select();
        return;
      }
    }
  });
}

/**
 * Search box state. `q` is the committed query from the URL (?q=), and `commit` writes a new one.
 * The draft follows typing immediately and is committed after a short pause. A URL change this
 * hook did not make (back/forward, switching views) resets the draft to match the URL.
 */
export function useSearch(q: string, commit: (q: string) => void) {
  const [draft, setDraft] = useState(q);
  const [expanded, setExpanded] = useState(q !== "");
  // `committed` is the last query this hook sent to the URL; `seenQ` the last URL query rendered.
  const [committed, setCommitted] = useState(q);
  const [seenQ, setSeenQ] = useState(q);
  if (q !== seenQ) {
    setSeenQ(q);
    if (q !== committed) {
      setDraft(q);
      setCommitted(q);
      setExpanded(q !== "");
    }
  }

  // `commit` usually closes over the current nav, so it is new every render; read it from a ref
  // so re-renders (clock ticks, list loads) don't restart the debounce timer.
  const commitRef = useRef(commit);
  useEffect(() => {
    commitRef.current = commit;
  }, [commit]);

  const send = useCallback((next: string) => {
    setCommitted(next);
    commitRef.current(next);
  }, []);

  useEffect(() => {
    const next = draft.trim();
    if (next === committed) return;
    const t = setTimeout(() => send(next), SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(t);
  }, [draft, committed, send]);

  /** Opens the field (if needed) and focuses it. */
  const show = useCallback(() => {
    setExpanded(true);
    focusVisibleInput();
  }, []);

  /** Empties the field and drops the query, keeping the field open. */
  const clear = useCallback(() => {
    setDraft("");
    if (committed !== "") send("");
  }, [committed, send]);

  /** Empties and closes the field. */
  const close = useCallback(() => {
    clear();
    setExpanded(false);
  }, [clear]);

  /** Commits the draft now instead of waiting out the debounce (Enter). */
  const flush = useCallback(() => {
    const next = draft.trim();
    if (next !== committed) send(next);
  }, [draft, committed, send]);

  return { draft, setDraft, open: expanded, show, clear, close, flush };
}
