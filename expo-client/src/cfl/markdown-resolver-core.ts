/** Reject absent, malformed or unavailable TurboModules without falling back open. */
export function hasMarkdownParser(lookup: (name: string) => unknown): boolean {
  try {
    const module = lookup('EnrichedMarkdownParser') as { collect?: unknown } | null;
    return typeof module?.collect === 'function';
  } catch { return false; }
}
