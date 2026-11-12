// Never forward the new native event prop to an older binary or Web View.
export function sequentialEventProp<T>(available: boolean, onSequentialHandoff: T | undefined): {onSequentialHandoff?: T} {
  return available && onSequentialHandoff !== undefined ? {onSequentialHandoff} : {};
}
