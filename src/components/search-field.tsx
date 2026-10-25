"use client";
import { CloseIcon, SearchIcon } from "./icons";

/**
 * The list's search input. "desktop" sits in the 54px list header; "phone" is a full-width row
 * under the phone/tablet title (16px text so iOS doesn't zoom on focus, 44px tall).
 * Esc clears and closes; Enter commits right away and leaves the field so j/k work on results.
 */
export function SearchField({
  variant,
  value,
  placeholder,
  onChange,
  onSubmit,
  onClear,
  onClose,
}: {
  variant: "desktop" | "phone";
  value: string;
  placeholder: string;
  onChange: (v: string) => void;
  onSubmit: () => void;
  onClear: () => void;
  onClose: () => void;
}) {
  const phone = variant === "phone";
  const empty = value.trim() === "";
  return (
    <div
      role="search"
      className={`flex min-w-0 flex-1 items-center rounded-lg bg-[var(--code)] text-[var(--muted)] ring-1 ring-inset ring-transparent focus-within:ring-[var(--accent)]/60 ${
        phone ? "h-11 pl-3" : "h-[30px] pl-2"
      }`}
    >
      <SearchIcon size={phone ? 18 : 15} className="shrink-0" />
      <input
        data-search=""
        type="search"
        enterKeyHint="search"
        autoComplete="off"
        spellCheck={false}
        aria-label="Search items"
        placeholder={placeholder}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            // Stop here so the app's Esc (leave full screen) doesn't also run.
            e.preventDefault();
            e.stopPropagation();
            e.currentTarget.blur();
            onClose();
          } else if (e.key === "Enter") {
            e.preventDefault();
            onSubmit();
            e.currentTarget.blur();
          }
        }}
        // An empty field folds back into the search button when focus leaves it.
        onBlur={() => empty && onClose()}
        className={`min-w-0 flex-1 bg-transparent text-[var(--ink)] outline-none focus-visible:outline-none placeholder:text-[var(--faint)] [&::-webkit-search-cancel-button]:appearance-none ${
          phone ? "px-2 text-[16px]" : "px-1.5 text-[14px]"
        }`}
      />
      <button
        type="button"
        // Keep focus in the input so clearing doesn't trigger the empty-blur close first.
        onMouseDown={(e) => e.preventDefault()}
        onClick={empty ? onClose : onClear}
        aria-label={empty ? "Close search" : "Clear search"}
        className={`inline-flex shrink-0 items-center justify-center rounded-lg hover:text-[var(--ink)] ${
          phone ? "h-11 w-11" : "h-[30px] w-[30px]"
        }`}
      >
        <CloseIcon size={phone ? 18 : 15} />
      </button>
    </div>
  );
}
