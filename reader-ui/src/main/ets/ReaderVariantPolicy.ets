import { ReaderVariantPreference, ReaderPage } from '@reader-kit/core'

export type ReaderVariantSelectionResult = 'changed' | 'unchanged' | 'unavailable' | 'stale'

/** Host-owned processed-image policy; services, persistence and processing remain outside reader-kit. */
export class ReaderVariantPolicy {
  readonly automaticNext: boolean
  private processingResolver: ((page: ReaderPage, automatic: boolean) => ReaderVariantPreference) | null
  readonly revision: number
  private readonly fallback: ReaderVariantPreference
  private readonly resolver: ((sourceIndex: number) => ReaderVariantPreference) | null
  private readonly onSelection: ((sourceIndex: number, preference: ReaderVariantPreference,
    result: ReaderVariantSelectionResult) => void) | null

  constructor(fallback: ReaderVariantPreference = new ReaderVariantPreference(), revision: number = 0,
    resolver: ((sourceIndex: number) => ReaderVariantPreference) | null = null,
    onSelection: ((sourceIndex: number, preference: ReaderVariantPreference,
      result: ReaderVariantSelectionResult) => void) | null = null,
    processingResolver: ((page: ReaderPage, automatic: boolean) => ReaderVariantPreference) | null = null,
    automaticNext: boolean = false) {
    this.processingResolver = processingResolver
    this.automaticNext = automaticNext
    this.fallback = new ReaderVariantPreference(fallback.variant, fallback.identity)
    this.revision = revision
    this.resolver = resolver
    this.onSelection = onSelection
  }

  supportsProcessing(): boolean { return this.processingResolver !== null }

  processingPreference(page: ReaderPage, automatic: boolean): ReaderVariantPreference {
    return this.processingResolver?.(page.copy(), automatic) ?? this.preference(page.sourceIndex)
  }

  defaultPreference(): ReaderVariantPreference {
    return new ReaderVariantPreference(this.fallback.variant, this.fallback.identity)
  }

  hasPerSourcePreference(): boolean {
    return this.resolver !== null
  }

  preference(sourceIndex: number): ReaderVariantPreference {
    const value = this.resolver?.(sourceIndex) ?? this.fallback
    return new ReaderVariantPreference(value.variant, value.identity)
  }

  selectionCompleted(sourceIndex: number, preference: ReaderVariantPreference,
    result: ReaderVariantSelectionResult): void {
    this.onSelection?.(sourceIndex, new ReaderVariantPreference(preference.variant, preference.identity), result)
  }
}
