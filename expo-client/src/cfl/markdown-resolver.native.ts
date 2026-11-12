import { TurboModuleRegistry, type TurboModule } from 'react-native';
import { hasMarkdownParser } from './markdown-resolver-core';

/** A missing native parser makes the nightly renderer fall back to original URLs. */
export function markdownImageResolverAvailable(): boolean {
  return hasMarkdownParser(name => TurboModuleRegistry.get<TurboModule>(name));
}
