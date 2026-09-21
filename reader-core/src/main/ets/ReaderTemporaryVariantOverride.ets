import { ReaderPage, ReaderUnitKey } from './ReaderContent'
import { ReaderVariantPreference } from './ReaderSession'

/** A canonical source identity within the one currently rendered Reader unit. */
export class ReaderTemporaryVariantSource {
  sourceIndex: number
  pageKey: string

  constructor(sourceIndex: number, pageKey: string) {
    this.sourceIndex = sourceIndex
    this.pageKey = pageKey
  }

  copy(): ReaderTemporaryVariantSource {
    return new ReaderTemporaryVariantSource(this.sourceIndex, this.pageKey)
  }

  equals(other: ReaderTemporaryVariantSource): boolean {
    return this.sourceIndex === other.sourceIndex && this.pageKey === other.pageKey
  }
}

/**
 * One rendered Reader unit. Navigation revision is deliberately included: a
 * rebuilt display is not allowed to inherit a route-only temporary override.
 */
export class ReaderTemporaryVariantScope {
  unit: ReaderUnitKey
  navigationRevision: number
  sources: ReaderTemporaryVariantSource[]

  constructor(unit: ReaderUnitKey, navigationRevision: number, sources: ReaderTemporaryVariantSource[]) {
    this.unit = unit.copy()
    this.navigationRevision = navigationRevision
    this.sources = sources.map((source: ReaderTemporaryVariantSource): ReaderTemporaryVariantSource => source.copy())
      .sort((left: ReaderTemporaryVariantSource, right: ReaderTemporaryVariantSource): number =>
        left.sourceIndex === right.sourceIndex ? left.pageKey.localeCompare(right.pageKey) : left.sourceIndex - right.sourceIndex)
  }

  static fromPages(unit: ReaderUnitKey, navigationRevision: number, pages: ReaderPage[]): ReaderTemporaryVariantScope {
    return new ReaderTemporaryVariantScope(unit, navigationRevision,
      pages.map((page: ReaderPage): ReaderTemporaryVariantSource =>
        new ReaderTemporaryVariantSource(page.sourceIndex, page.key)))
  }

  copy(): ReaderTemporaryVariantScope {
    return new ReaderTemporaryVariantScope(this.unit, this.navigationRevision, this.sources)
  }

  equals(other: ReaderTemporaryVariantScope): boolean {
    return this.unit.equals(other.unit) && this.navigationRevision === other.navigationRevision &&
      this.sources.length === other.sources.length && this.sources.every(
        (source: ReaderTemporaryVariantSource, index: number): boolean => source.equals(other.sources[index]))
  }

  contains(sourceIndex: number, pageKey: string): boolean {
    return this.sources.some((source: ReaderTemporaryVariantSource): boolean =>
      source.sourceIndex === sourceIndex && source.pageKey === pageKey)
  }
}

/**
 * Route-memory-only suppression of an enhanced variant for the current rendered
 * unit. It never persists a host preference. Its revision is included in the
 * Surface selection context, which cancels a processed preparation before a
 * changed temporary policy can be resolved.
 */
export class ReaderTemporaryVariantOverride {
  revision: number = 0
  private disabledScope: ReaderTemporaryVariantScope | null = null

  isDisabled(scope: ReaderTemporaryVariantScope | null): boolean {
    return scope !== null && this.disabledScope?.equals(scope) === true
  }

  reconcile(scope: ReaderTemporaryVariantScope | null): void {
    if (this.disabledScope !== null && (scope === null || !this.disabledScope.equals(scope))) this.clear()
  }

  toggle(scope: ReaderTemporaryVariantScope): boolean {
    if (this.isDisabled(scope)) {
      this.clear()
      return true
    }
    this.disabledScope = scope.copy()
    this.revision += 1
    return false
  }

  clear(): void {
    if (this.disabledScope === null) return
    this.disabledScope = null
    this.revision += 1
  }

  preference(scope: ReaderTemporaryVariantScope | null, sourceIndex: number, pageKey: string,
    fallback: ReaderVariantPreference): ReaderVariantPreference {
    if (this.isDisabled(scope) && this.disabledScope?.contains(sourceIndex, pageKey) === true &&
      fallback.variant === 'enhanced') return new ReaderVariantPreference()
    return new ReaderVariantPreference(fallback.variant, fallback.identity)
  }
}
