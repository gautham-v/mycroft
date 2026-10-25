// Folder/source ordering shared by the desktop sidebar and the phone Sources page.
import type { Folder, Source } from "./types";

/** Sources within one folder: by saved position, then title. */
export const byPosition = (a: Source, b: Source) => a.position - b.position || a.title.localeCompare(b.title);

/** Folders in sidebar order. */
export function orderFolders(folders: Folder[]): Folder[] {
  return [...folders].sort((a, b) => a.position - b.position || a.id - b.id);
}

/** The sources in one folder (null = unfiled), in sidebar order. */
export function sourcesIn(sources: Source[], folderId: number | null): Source[] {
  return sources.filter((s) => s.folder_id === folderId).sort(byPosition);
}
