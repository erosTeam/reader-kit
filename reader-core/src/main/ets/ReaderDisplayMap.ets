import { ReaderPage, ReaderUnit, ReaderUnitKey } from './ReaderContent'

export type ReaderFragment = 'whole' | 'left' | 'right'
export type ReaderDirection = 'ltr' | 'rtl'
export type ReaderLayout = 'single' | 'spread' | 'continuous'
export type ReaderPagingAxis = 'horizontal' | 'vertical'
export type ReaderSpreadLayout = 'joined' | 'split'

/** Runtime layout policy, not a new preference store or host enum mapping. */
export class ReaderDisplayPolicy {
  layout: ReaderLayout = 'single'
  /** The session resolves the effective layout from the measured viewport. */
  automaticPaging: boolean = false
  pagingAxis: ReaderPagingAxis = 'horizontal'
  spreadLayout: ReaderSpreadLayout = 'joined'
  direction: ReaderDirection = 'ltr'
  firstPageAlone: boolean = false
  splitWidePages: boolean = false
  rotateWidePages: boolean = false
  /** Hosts may keep wide-page settings dormant in continuous reading. */
  rotateWidePagesInContinuous: boolean = true
  widePageRatio: number = 1.2

  equals(other: ReaderDisplayPolicy): boolean {
    return this.automaticPaging === other.automaticPaging && this.layout === other.layout &&
      this.pagingAxis === other.pagingAxis && this.direction === other.direction &&
      this.spreadLayout === other.spreadLayout && this.firstPageAlone === other.firstPageAlone &&
      this.splitWidePages === other.splitWidePages && this.rotateWidePages === other.rotateWidePages &&
      this.rotateWidePagesInContinuous === other.rotateWidePagesInContinuous && this.widePageRatio === other.widePageRatio
  }

  copy(): ReaderDisplayPolicy {
    const value = new ReaderDisplayPolicy()
    value.layout = this.layout
    value.automaticPaging = this.automaticPaging
    value.pagingAxis = this.pagingAxis
    value.spreadLayout = this.spreadLayout
    value.direction = this.direction
    value.firstPageAlone = this.firstPageAlone
    value.splitWidePages = this.splitWidePages
    value.rotateWidePages = this.rotateWidePages
    value.rotateWidePagesInContinuous = this.rotateWidePagesInContinuous
    value.widePageRatio = this.widePageRatio
    return value
  }
}

/** Wide-page decisions use original metadata, never independent thumbnail dimensions. */
export function readerPageIsWide(page: ReaderPage | null, widePageRatio: number): boolean {
  return page !== null && Number.isFinite(page.width) && Number.isFinite(page.height) &&
    Number.isFinite(widePageRatio) && widePageRatio > 1 &&
    page.width > 0 && page.height > 0 && page.width / page.height >= widePageRatio
}

export function readerPolicyRotatesPage(policy: ReaderDisplayPolicy, page: ReaderPage | null): boolean {
  return policy.rotateWidePages && !policy.splitWidePages &&
    !(policy.automaticPaging && policy.layout === 'spread') &&
    (policy.layout !== 'continuous' || policy.rotateWidePagesInContinuous) && readerPageIsWide(page, policy.widePageRatio)
}

function normalized(value: number, fallback: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : fallback
}

/** Coordinates are normalized in the ORIGINAL page, never in a spread or crop. */
export class ReaderReadingAnchor {
  unit: ReaderUnitKey
  pageKey: string | null
  sourceIndexHint: number
  x: number
  y: number
  fragment: ReaderFragment

  constructor(
    unit: ReaderUnitKey, pageKey: string | null, sourceIndexHint: number,
    x: number = 0.5, y: number = 0, fragment: ReaderFragment = 'whole',
  ) {
    this.unit = unit.copy()
    this.pageKey = pageKey
    this.sourceIndexHint = sourceIndexHint
    this.x = normalized(x, 0.5)
    this.y = normalized(y, 0)
    this.fragment = fragment
  }

  copy(): ReaderReadingAnchor {
    return new ReaderReadingAnchor(this.unit, this.pageKey, this.sourceIndexHint, this.x, this.y, this.fragment)
  }
}

/** Unknown metadata has a null pageKey, not an invented stable index identity. */
export class ReaderDisplayPart {
  unit: ReaderUnitKey
  pageKey: string | null
  sourceIndex: number
  fragment: ReaderFragment

  constructor(unit: ReaderUnitKey, pageKey: string | null, sourceIndex: number, fragment: ReaderFragment = 'whole') {
    this.unit = unit.copy()
    this.pageKey = pageKey
    this.sourceIndex = sourceIndex
    this.fragment = fragment
  }

  left(): number { return this.fragment === 'right' ? 0.5 : 0 }
  width(): number { return this.fragment === 'whole' ? 1 : 0.5 }

  copy(): ReaderDisplayPart { return new ReaderDisplayPart(this.unit, this.pageKey, this.sourceIndex, this.fragment) }
}

export class ReaderDisplayItem {
  /** Logical/source order. An RTL Row may reverse these parts, not their identities. */
  parts: ReaderDisplayPart[]

  constructor(parts: ReaderDisplayPart[]) {
    this.parts = parts.map((part: ReaderDisplayPart) => part.copy())
  }

  visualParts(direction: ReaderDirection): ReaderDisplayPart[] {
    const parts = this.parts.map((part: ReaderDisplayPart) => part.copy())
    return direction === 'rtl' ? parts.reverse() : parts
  }

  copy(): ReaderDisplayItem { return new ReaderDisplayItem(this.parts) }
}

export type ReaderAnchorMatch = 'page-key' | 'index-hint' | 'index-fallback' |
  'pending-metadata' | 'missing-page' | 'wrong-unit' | 'empty'

export class ReaderAnchorResolution {
  match: ReaderAnchorMatch
  displayIndex: number = -1
  /** Logical part index, not the position within an RTL Row. */
  partIndex: number = -1
  anchor: ReaderReadingAnchor | null = null
  localX: number = 0
  localY: number = 0

  constructor(match: ReaderAnchorMatch) { this.match = match }

  resolved(): boolean { return this.displayIndex >= 0 }
}

/**
 * Single-unit, platform-free display topology. Metadata updates retain topology
 * unless wide-page splitting or automatic spread boundaries change. The source anchor
 * survives layout changes; display mapping never writes progress.
 * Pairing follows E/N's cover-alignment rule. Splitting follows Koma's paged-only
 * left/right expansion; spread and continuous layouts never silently split.
 */
export class ReaderDisplayMap {
  private readonly unit: ReaderUnit
  private readonly policy: ReaderDisplayPolicy
  private readonly metadata: Map<number, ReaderPage> = new Map()
  private readonly pageIndexes: Map<string, number> = new Map()
  private readonly items: ReaderDisplayItem[] = []

  constructor(unit: ReaderUnit, pages: ReaderPage[], policy: ReaderDisplayPolicy = new ReaderDisplayPolicy(),
    stablePrefix: ReaderDisplayItem[] = [], singlePages: Set<number> = new Set<number>(),
    seenPairs: Set<number> = new Set<number>()) {
    if (!Number.isSafeInteger(unit.pageCount) || unit.pageCount < 0) {
      throw new Error('reader_invalid_page_count')
    }
    if (!Number.isFinite(policy.widePageRatio) || policy.widePageRatio <= 1) {
      throw new Error('reader_invalid_wide_ratio')
    }
    this.unit = unit.copy()
    this.policy = policy.copy()
    pages.forEach((page: ReaderPage) => {
      if (!page.unit.equals(this.unit.key) || !Number.isInteger(page.sourceIndex) ||
        page.sourceIndex < 0 || page.sourceIndex >= this.unit.pageCount || page.key.length === 0 ||
        this.metadata.has(page.sourceIndex) || this.pageIndexes.has(page.key)) {
        throw new Error('reader_invalid_page_metadata')
      }
      this.metadata.set(page.sourceIndex, page.copy())
      this.pageIndexes.set(page.key, page.sourceIndex)
    })
    this.build(stablePrefix, singlePages, seenPairs)
  }

  count(): number { return this.items.length }

  /** Keep displayed groups stable when later metadata changes upcoming pairs. */
  prefixThrough(sourceIndex: number): ReaderDisplayItem[] {
    const prefix: ReaderDisplayItem[] = []
    for (const item of this.items) {
      if (item.parts[0].sourceIndex > sourceIndex) break
      prefix.push(item.copy())
    }
    return prefix
  }

  private occupiesSpread(page: ReaderPage | undefined): boolean {
    return page !== undefined && Number.isFinite(page.width) && Number.isFinite(page.height) &&
      page.width > 0 && page.height > 0 && page.width >= page.height
  }

  item(index: number): ReaderDisplayItem | null {
    if (!Number.isInteger(index) || index < 0 || index >= this.items.length) return null
    const value = this.items[index].copy()
    value.parts.forEach((part: ReaderDisplayPart): void => {
      part.pageKey = this.metadata.get(part.sourceIndex)?.key ?? null
    })
    return value
  }

  /** False asks the session to rebuild display groups. Automatic pairing still records the page. */
  updatePage(page: ReaderPage): boolean {
    const existingIndex = this.pageIndexes.get(page.key)
    if (!page.unit.equals(this.unit.key) || !Number.isInteger(page.sourceIndex) ||
      page.sourceIndex < 0 || page.sourceIndex >= this.unit.pageCount || page.key.length === 0 ||
      (existingIndex !== undefined && existingIndex !== page.sourceIndex)) {
      throw new Error('reader_invalid_page_metadata')
    }
    const previous = this.metadata.get(page.sourceIndex)
    if (this.policy.layout === 'single' && this.policy.splitWidePages &&
      readerPageIsWide(previous ?? null, this.policy.widePageRatio) !==
      readerPageIsWide(page, this.policy.widePageRatio)) return false
    const pairingChanged = this.policy.automaticPaging && this.policy.layout === 'spread' &&
      (this.occupiesSpread(previous) !== this.occupiesSpread(page) ||
        readerPageIsWide(previous ?? null, this.policy.widePageRatio) !==
        readerPageIsWide(page, this.policy.widePageRatio))
    if (previous !== undefined && previous.key !== page.key) this.pageIndexes.delete(previous.key)
    this.metadata.set(page.sourceIndex, page.copy())
    this.pageIndexes.set(page.key, page.sourceIndex)
    return !pairingChanged
  }

  /** Logical next/previous stays the same in RTL and never crosses a unit. */
  neighbor(index: number, direction: 'next' | 'previous'): number | null {
    if (!Number.isInteger(index) || index < 0 || index >= this.items.length) return null
    const target = index + (direction === 'next' ? 1 : -1)
    return target >= 0 && target < this.items.length ? target : null
  }

  isLastDisplayItem(index: number): boolean {
    return this.items.length > 0 && index === this.items.length - 1
  }

  private part(index: number, fragment: ReaderFragment = 'whole'): ReaderDisplayPart {
    const page = this.metadata.get(index)
    return new ReaderDisplayPart(this.unit.key, page === undefined ? null : page.key, index, fragment)
  }

  private shouldSplit(index: number): boolean {
    if (this.policy.layout !== 'single' || !this.policy.splitWidePages) return false
    const page = this.metadata.get(index)
    return readerPageIsWide(page ?? null, this.policy.widePageRatio)
  }

  private buildAutomaticSpread(stablePrefix: ReaderDisplayItem[], singlePages: Set<number>,
    seenPairs: Set<number>): void {
    let start = 0
    stablePrefix.forEach((item: ReaderDisplayItem): void => {
      this.items.push(item.copy())
      start += item.parts.length
    })
    while (start < this.unit.pageCount) {
      if (this.occupiesSpread(this.metadata.get(start)) || singlePages.has(start) ||
        (start === 0 && this.policy.firstPageAlone)) {
        this.items.push(new ReaderDisplayItem([this.part(start)]))
        start++
        continue
      }
      if (this.isSeenPair(start, singlePages, seenPairs)) {
        this.items.push(new ReaderDisplayItem([this.part(start), this.part(start + 1)]))
        start += 2
        continue
      }
      // Keep slots for unknown sizes. Only confirmed horizontal spreads or a
      // reader-selected boundary can change alignment, never download order.
      let end = start + 1
      while (end < this.unit.pageCount && !singlePages.has(end) && !this.occupiesSpread(this.metadata.get(end)) &&
        !this.isSeenPair(end, singlePages, seenPairs)) end++
      const startsAfterExplicitSingle = (start === 1 && this.policy.firstPageAlone) || singlePages.has(start - 1)
      const endsAtSpread = readerPageIsWide(this.metadata.get(end) ?? null, this.policy.widePageRatio)
      if (endsAtSpread && !startsAfterExplicitSingle && (end - start) % 2 !== 0) {
        // OpenComic and KCC align the preceding run backwards from a full
        // spread. The first page in an odd run is the one left on its own.
        this.items.push(new ReaderDisplayItem([this.part(start)]))
        start++
      }
      while (start < end) {
        const parts: ReaderDisplayPart[] = [this.part(start++)]
        if (start < end) parts.push(this.part(start++))
        this.items.push(new ReaderDisplayItem(parts))
      }
    }
  }

  private isSeenPair(index: number, singlePages: Set<number>, seenPairs: Set<number>): boolean {
    return seenPairs.has(index) && index + 1 < this.unit.pageCount && !singlePages.has(index + 1) &&
      !this.occupiesSpread(this.metadata.get(index)) && !this.occupiesSpread(this.metadata.get(index + 1))
  }

  private build(stablePrefix: ReaderDisplayItem[], singlePages: Set<number>, seenPairs: Set<number>): void {
    if (this.policy.automaticPaging && this.policy.layout === 'spread') {
      this.buildAutomaticSpread(stablePrefix, singlePages, seenPairs)
      return
    }
    let index = 0
    while (index < this.unit.pageCount) {
      if (this.policy.layout === 'spread') {
        const parts: ReaderDisplayPart[] = [this.part(index)]
        if (!(index === 0 && this.policy.firstPageAlone) && index + 1 < this.unit.pageCount) {
          parts.push(this.part(index + 1))
          index += 1
        }
        this.items.push(new ReaderDisplayItem(parts))
      } else if (this.shouldSplit(index)) {
        const first: ReaderFragment = this.policy.direction === 'rtl' ? 'right' : 'left'
        const second: ReaderFragment = first === 'left' ? 'right' : 'left'
        this.items.push(new ReaderDisplayItem([this.part(index, first)]))
        this.items.push(new ReaderDisplayItem([this.part(index, second)]))
      } else {
        this.items.push(new ReaderDisplayItem([this.part(index)]))
      }
      index += 1
    }
  }

  /** localX/localY come from a UI observation within one displayed part. */
  anchorAt(displayIndex: number, partIndex: number = 0, localX: number = 0.5, localY: number = 0): ReaderReadingAnchor | null {
    const item = this.item(displayIndex)
    if (item === null || !Number.isInteger(partIndex) || partIndex < 0 || partIndex >= item.parts.length) return null
    const part = item.parts[partIndex]
    return new ReaderReadingAnchor(part.unit, part.pageKey, part.sourceIndex,
      part.left() + normalized(localX, 0.5) * part.width(), normalized(localY, 0), part.fragment)
  }

  /** Missing stable identities do not silently become another page at the old index. */
  resolve(anchor: ReaderReadingAnchor, allowIndexFallback: boolean = false): ReaderAnchorResolution {
    if (!anchor.unit.equals(this.unit.key)) return new ReaderAnchorResolution('wrong-unit')
    if (this.items.length === 0) return new ReaderAnchorResolution('empty')
    let index = anchor.pageKey === null ? undefined : this.pageIndexes.get(anchor.pageKey)
    let match: ReaderAnchorMatch = 'page-key'
    if (index === undefined) {
      const hint = Number.isFinite(anchor.sourceIndexHint) ? Math.floor(anchor.sourceIndexHint) : 0
      const boundedHint = Math.max(0, Math.min(this.unit.pageCount - 1, hint))
      if (anchor.pageKey !== null && !allowIndexFallback) {
        return new ReaderAnchorResolution(this.metadata.size < this.unit.pageCount ? 'pending-metadata' : 'missing-page')
      }
      index = boundedHint
      match = anchor.pageKey === null ? 'index-hint' : 'index-fallback'
    }
    let preferred: ReaderFragment = anchor.fragment
    if (preferred === 'whole') {
      preferred = anchor.x === 0.5 ? (this.policy.direction === 'rtl' ? 'right' : 'left') :
        (anchor.x < 0.5 ? 'left' : 'right')
    }
    for (let displayIndex = 0; displayIndex < this.items.length; displayIndex += 1) {
      const item = this.items[displayIndex]
      for (let partIndex = 0; partIndex < item.parts.length; partIndex += 1) {
        const part = item.parts[partIndex]
        if (part.sourceIndex !== index || (part.fragment !== 'whole' && part.fragment !== preferred)) continue
        const result = new ReaderAnchorResolution(match)
        result.displayIndex = displayIndex
        result.partIndex = partIndex
        result.anchor = new ReaderReadingAnchor(this.unit.key, this.metadata.get(index)?.key ?? null, index,
          anchor.x, anchor.y, part.fragment === 'whole' ? anchor.fragment : part.fragment)
        result.localX = normalized((anchor.x - part.left()) / part.width(), 0.5)
        result.localY = normalized(anchor.y, 0)
        return result
      }
    }
    return new ReaderAnchorResolution('missing-page')
  }
}
