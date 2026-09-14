/**
 * ArkUI ForEach/LazyForEach element keys accept only letters, digits and
 * underscores. Reader identities deliberately contain richer separators and
 * host-owned text, so encode them at the rendering boundary instead of
 * weakening their domain meaning.
 */
export function readerElementKey(value: string): string {
  let key = 'rk'
  for (let index = 0; index < value.length; index += 1) {
    key += `_${value.charCodeAt(index).toString(16)}`
  }
  return key
}
