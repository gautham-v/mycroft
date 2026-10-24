import type { SVGProps } from "react";

type P = SVGProps<SVGSVGElement> & { size?: number };

function Base({ size = 18, children, ...rest }: P) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const ArcIcon = (p: P) => (
  <Base {...p}>
    <path d="M5 11a8 8 0 0 1 8 8" />
    <path d="M5 5a14 14 0 0 1 14 14" />
    <circle cx="6" cy="18" r="1" fill="currentColor" />
  </Base>
);
export const RefreshIcon = (p: P) => (
  <Base {...p}>
    <path d="M20 11a8 8 0 0 0-14.9-3.5L4 9" />
    <path d="M4 4v5h5" />
    <path d="M4 13a8 8 0 0 0 14.9 3.5L20 15" />
    <path d="M20 20v-5h-5" />
  </Base>
);
export const BookmarkIcon = ({ filled, ...p }: P & { filled?: boolean }) => (
  <Base {...p}>
    <path d="M6 4h12v16l-6-4-6 4z" fill={filled ? "currentColor" : "none"} />
  </Base>
);
export const ExternalIcon = (p: P) => (
  <Base {...p}>
    <path d="M14 4h6v6" />
    <path d="M20 4l-9 9" />
    <path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" />
  </Base>
);
export const ExpandIcon = (p: P) => (
  <Base {...p}>
    <path d="M15 4h5v5" />
    <path d="M20 4l-6 6" />
    <path d="M9 20H4v-5" />
    <path d="M4 20l6-6" />
  </Base>
);
export const CollapseIcon = (p: P) => (
  <Base {...p}>
    <path d="M20 9h-5V4" />
    <path d="M15 9l6-6" />
    <path d="M4 15h5v5" />
    <path d="M9 15l-6 6" />
  </Base>
);
export const ShareIcon = (p: P) => (
  <Base {...p}>
    <path d="M12 3v12" />
    <path d="M8 7l4-4 4 4" />
    <path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7" />
  </Base>
);
export const CheckIcon = (p: P) => (
  <Base {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Base>
);
export const BackIcon = (p: P) => (
  <Base {...p}>
    <path d="M15 5l-7 7 7 7" />
  </Base>
);
export const PlusIcon = (p: P) => (
  <Base {...p}>
    <path d="M12 5v14M5 12h14" />
  </Base>
);
export const CloseIcon = (p: P) => (
  <Base {...p}>
    <path d="M6 6l12 12M18 6L6 18" />
  </Base>
);
export const ListIcon = (p: P) => (
  <Base {...p}>
    <path d="M4 6h16M4 12h16M4 18h10" />
  </Base>
);
export const InboxIcon = (p: P) => (
  <Base {...p}>
    <path d="M4 13l2.5-8h11L20 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z" />
    <path d="M4 13h5l1 2h4l1-2h5" />
  </Base>
);
export const PlayIcon = (p: P) => (
  <Base {...p}>
    <path d="M8 5.5v13l11-6.5z" fill="currentColor" />
  </Base>
);
export const VideoIcon = (p: P) => (
  <Base {...p}>
    <rect x="3" y="5" width="18" height="14" rx="2" />
    <path d="M10 9.5v5l4.5-2.5z" />
  </Base>
);
export const CommentIcon = (p: P) => (
  <Base {...p}>
    <path d="M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4 3.5V16H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z" />
  </Base>
);
export const SidebarIcon = (p: P) => (
  <Base {...p}>
    <rect x="3.5" y="4.5" width="17" height="15" rx="2" />
    <path d="M9.5 4.5v15" />
  </Base>
);
