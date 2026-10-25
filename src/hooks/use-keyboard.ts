"use client";
import { useEffect, useRef } from "react";
import type { View } from "@/lib/types";

/** What the app does for each shortcut. Read from a ref, so a new object every render is fine. */
export interface KeyboardActions {
  toggleSidebar: () => void;
  toggleFocusMode: () => void;
  /** Esc outside an input or dialog: clear an open search, else leave the full-screen reader. */
  escape: () => void;
  /** Select the next (1) or previous (-1) item in the list. */
  move: (step: 1 | -1) => void;
  openOriginal: () => void;
  toggleSaved: () => void;
  refresh: () => void;
  focusSearch: () => void;
  goView: (view: View) => void;
  toggleHelp: () => void;
}

/** A shortcut as the help overlay shows it. `sep` reads between keys: "or" for alternatives,
 *  "then" for a chord; omitted means the keys are pressed together. */
export interface Shortcut {
  keys: string[];
  label: string;
  sep?: "or" | "then";
}

/** The help overlay's contents, in display order. Keep in step with the handler below. */
export const SHORTCUTS: { group: string; items: Shortcut[] }[] = [
  {
    group: "Items",
    items: [
      { keys: ["j", "↓"], label: "Next item", sep: "or" },
      { keys: ["k", "↑"], label: "Previous item", sep: "or" },
      { keys: ["o", "Enter"], label: "Open original in a new tab", sep: "or" },
      { keys: ["s"], label: "Save or unsave" },
    ],
  },
  {
    group: "Views",
    items: [
      { keys: ["g", "a"], label: "All", sep: "then" },
      { keys: ["g", "s"], label: "Saved", sep: "then" },
      { keys: ["g", "v"], label: "Video", sep: "then" },
      { keys: ["g", "p"], label: "Podcasts", sep: "then" },
    ],
  },
  {
    group: "App",
    items: [
      { keys: ["/"], label: "Search" },
      { keys: ["r"], label: "Refresh feeds" },
      { keys: ["⌘", "\\"], label: "Show or hide the sidebar" },
      { keys: ["⇧", "⌘", "F"], label: "Full-screen reader" },
      { keys: ["Esc"], label: "Clear search, or leave full screen" },
      { keys: ["?"], label: "Show these shortcuts" },
    ],
  },
];

/** Second key of a "g" chord → view. */
const CHORDS: Record<string, View> = { a: "all", s: "saved", v: "video", p: "podcasts" };
const CHORD_MS = 1000;
// Single-key shortcuts need the list and reader side by side, so they are off on phones.
const MD_QUERY = "(min-width: 768px)";

function isTyping(t: EventTarget | null) {
  if (!(t instanceof HTMLElement)) return false;
  return t.isContentEditable || t.matches("input, textarea, select");
}

/**
 * Global keyboard shortcuts. ⌘\, ⇧⌘F and Esc work everywhere (inputs and dialogs that handle Esc
 * stop it first); the single-key ones only on tablet/desktop, with focus outside text fields and
 * no dialog open.
 */
export function useKeyboard(actions: KeyboardActions) {
  const ref = useRef(actions);
  useEffect(() => {
    ref.current = actions;
  });

  useEffect(() => {
    // Time of a pending "g", or 0.
    let gAt = 0;
    // Clicking text in the reader leaves focus on <body>, so remember which pane was clicked last:
    // after a click in the reader, arrows scroll the article instead of changing the selection.
    let readerClicked = false;
    const onPointer = (e: PointerEvent) => {
      readerClicked = e.target instanceof Element && e.target.closest("main") != null;
    };
    const onKey = (e: KeyboardEvent) => {
      const a = ref.current;
      const mod = e.metaKey || e.ctrlKey;
      if (mod && !e.altKey && !e.shiftKey && e.key === "\\") {
        e.preventDefault();
        a.toggleSidebar();
        return;
      }
      if (mod && e.shiftKey && !e.altKey && e.key.toLowerCase() === "f") {
        e.preventDefault();
        a.toggleFocusMode();
        return;
      }
      if (e.key === "Escape") {
        a.escape();
        return;
      }

      if (mod || e.altKey || e.defaultPrevented || e.isComposing) return;
      if (isTyping(e.target) || document.querySelector("dialog[open]")) return;
      if (!window.matchMedia(MD_QUERY).matches) return;
      const target = e.target instanceof HTMLElement ? e.target : null;

      if (gAt && e.timeStamp - gAt < CHORD_MS) {
        gAt = 0;
        const view = CHORDS[e.key];
        if (view) {
          e.preventDefault();
          a.goView(view);
        }
        return;
      }
      gAt = 0;

      switch (e.key) {
        case "ArrowDown":
        case "ArrowUp":
          // Arrows keep scrolling the article when focus is in, or the last click was on, the reader.
          if (readerClicked || target?.closest("main")) return;
          e.preventDefault();
          a.move(e.key === "ArrowDown" ? 1 : -1);
          return;
        case "j":
        case "k":
          e.preventDefault();
          a.move(e.key === "j" ? 1 : -1);
          return;
        case "Enter":
          // Enter still activates focused buttons and links, except list rows (they're already open).
          if (target?.closest("button, a, summary, [role=button]") && !target.closest(".item-row")) return;
          e.preventDefault();
          a.openOriginal();
          return;
        case "o":
          e.preventDefault();
          a.openOriginal();
          return;
        case "s":
          e.preventDefault();
          a.toggleSaved();
          return;
        case "r":
          e.preventDefault();
          a.refresh();
          return;
        case "/":
          e.preventDefault();
          a.focusSearch();
          return;
        case "?":
          e.preventDefault();
          a.toggleHelp();
          return;
        case "g":
          gAt = e.timeStamp;
          return;
      }
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("pointerdown", onPointer, true);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pointerdown", onPointer, true);
    };
  }, []);
}
