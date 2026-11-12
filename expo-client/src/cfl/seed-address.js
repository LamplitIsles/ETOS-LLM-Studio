// The LAN entry is one explicitly configured RFC1918 IPv4 address, never a URL.
export function isPrivateIPv4(host) {
  if (typeof host !== 'string') return false;
  const parts = host.split('.');
  if (parts.length !== 4 || parts.some(part => !/^(0|[1-9][0-9]{0,2})$/.test(part) || Number(part) > 255)) return false;
  const [a, b] = parts.map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}
