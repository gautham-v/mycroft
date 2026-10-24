"use client";
import { useState } from "react";

// 8 colors, each >= 4.5:1 against white text.
const PALETTE = ["#0063CC", "#3B5BA9", "#8A3FA0", "#B23A48", "#9A5B00", "#2F7A3B", "#5A5A9E", "#7A5230"];

export function hostColor(host: string): string {
  let h = 0;
  for (let i = 0; i < host.length; i++) h = (h * 31 + host.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

export function SourceBadge({ host, title, size = 32 }: { host: string; title: string; size?: number }) {
  const [failed, setFailed] = useState(false);
  const letter = (title || host || "?").replace(/^the\s+/i, "").charAt(0).toUpperCase();
  const style = { width: size, height: size, borderRadius: Math.round(size * 0.29) };
  if (failed || !host) {
    return (
      <span
        aria-hidden="true"
        className="inline-flex shrink-0 items-center justify-center font-semibold text-white"
        style={{ ...style, background: hostColor(host || title), fontSize: Math.round(size * 0.45) }}
      >
        {letter}
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={`https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=64`}
      alt=""
      width={size}
      height={size}
      loading="lazy"
      onError={() => setFailed(true)}
      className="shrink-0 object-cover"
      style={style}
    />
  );
}
