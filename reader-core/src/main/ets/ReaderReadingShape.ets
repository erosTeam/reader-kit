import { ReaderImagePixelSize } from './ReaderImageHeaderProbe'

/**
 * Reading-shape evidence derived from original page dimensions.
 *
 * webtoon: at least the majority of known originals are clearly taller than wide.
 * paged:   enough known originals disagree; a host may stop sampling.
 * undecided: keep sampling; the evidence is not conclusive yet.
 */
export type ReaderReadingShape = 'webtoon' | 'paged' | 'undecided'

export interface ReaderReadingShapePolicy {
  /** A single known original at or above this height/width ratio settles it. */
  strongRatio: number
  /** Height/width ratio counted as a strip-like original in the majority rule. */
  longRatio: number
  /** Known originals required before the majority rule applies. */
  minimumKnown: number
  /** How many leading known originals the decision inspects. */
  sample: number
}

/**
 * Runtime dimensions come from the decoded/streamed original, so a strip-like
 * first page can be recognized before the list has finished loading. Catalog
 * dimensions may be missing or approximate and therefore stay conservative.
 */
export const READER_RUNTIME_SHAPE_POLICY: ReaderReadingShapePolicy = {
  // A single measured original settles only when it is unmistakably strip
  // shaped; ordinary portrait pages stay well below this. 1.9 keeps a first
  // page that is roughly twice as tall as wide readable as one strip block,
  // while the two-thirds rule below still governs ordinary multi-page sets.
  strongRatio: 1.9,
  longRatio: 1.6,
  minimumKnown: 2,
  sample: 6,
}

/** Catalog-declared dimensions: require several unmistakable long originals. */
export const READER_CATALOG_SHAPE_POLICY: ReaderReadingShapePolicy = {
  strongRatio: 3,
  longRatio: 3,
  minimumKnown: 3,
  sample: 6,
}

export function readerReadingShape(sizes: Array<ReaderImagePixelSize | undefined>,
  policy: ReaderReadingShapePolicy = READER_RUNTIME_SHAPE_POLICY): ReaderReadingShape {
  let known = 0
  let long = 0
  let strongest = 0
  for (let index = 0; index < sizes.length && known < policy.sample; index += 1) {
    const size = sizes[index]
    if (size === undefined) continue
    if (!(size.width > 0) || !(size.height > 0)) continue
    known += 1
    const ratio = size.height / size.width
    if (ratio >= policy.longRatio) long += 1
    if (ratio > strongest) strongest = ratio
  }
  if (known === 0) return 'undecided'
  if (known < policy.minimumKnown) {
    return strongest >= policy.strongRatio ? 'webtoon' : 'undecided'
  }
  if (long * 3 >= known * 2) return 'webtoon'
  return known >= 3 ? 'paged' : 'undecided'
}

/** True when the decoded original is tall enough to read as one strip block. */
export function readerImageIsStripLike(size: ReaderImagePixelSize,
  ratio: number = READER_RUNTIME_SHAPE_POLICY.longRatio): boolean {
  return size.width > 0 && size.height >= size.width * ratio
}
