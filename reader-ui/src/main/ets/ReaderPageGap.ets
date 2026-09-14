/** Bounded presentation spacing only; hosts retain their own preference names and persistence. */
export function normalizedReaderPageGap(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.max(0, Math.min(96, value))
}
