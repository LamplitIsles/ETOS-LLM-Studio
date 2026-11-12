import { fetch as expoFetch } from 'expo/fetch';

/** Expo fetch honors credentials: omit and redirect: error on iOS. */
export const externalImageFetch = expoFetch as typeof fetch;
