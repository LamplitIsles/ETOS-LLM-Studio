export function matchesEtag(value: string | null, etag: string): boolean {
  if (!value) return false;
  if (value.trim() === "*") return true;
  // Opaque tags can contain commas; parse quoted tags before list separators.
  const token = /(?:W\/)?"[\x21\x23-\x7e\x80-\xff]*"/gy;
  const maxEmptyElements = 16;
  let position = 0;
  let matched = false;
  let expectingElement = true;
  let emptyElements = 0;
  while (true) {
    while (position < value.length && /\s/.test(value[position]!)) position++;
    if (position === value.length) {
      if (expectingElement && ++emptyElements > maxEmptyElements) return false;
      return matched;
    }
    if (value[position] === ",") {
      if (expectingElement && ++emptyElements > maxEmptyElements) return false;
      expectingElement = true;
      position++;
      continue;
    }
    if (!expectingElement) return false;
    token.lastIndex = position;
    const part = token.exec(value);
    if (!part) return false;
    const tag = part[0];
    if (tag === etag || tag === `W/${etag}`) matched = true;
    position = token.lastIndex;
    expectingElement = false;
  }
}
