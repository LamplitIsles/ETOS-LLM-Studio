/** Browser fetch keeps cross-origin images subject to CORS. */
export const externalImageFetch: typeof fetch = (input, init) => globalThis.fetch(input, init);
