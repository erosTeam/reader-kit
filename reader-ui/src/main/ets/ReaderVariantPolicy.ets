import { ReaderVariantPreference } from '@reader-kit/core'

export type ReaderVariantSelectionResult = 'changed' | 'unchanged' | 'unavailable' | 'stale'

/** Host-owned processed-image policy; services, persistence and processing remain outside reader-kit. */
export class ReaderVariantPolicy {
  readonly revision: number
  private readonly fallback: ReaderVariantPreference
  private readonly resolver: ((sourceIndex: number) => ReaderVariantPreference) | null
  private readonly onSelection: ((sourceIndex: number, preference: ReaderVariantPreference,
    result: ReaderVariantSelectionResult) => void) | null

  constructor(fallback: ReaderVariantPreference = new ReaderVariantPreference(), revision: number = 0,
    resolver: ((sourceIndex: number) => ReaderVariantPreference) | null = null,
    onSelection: ((sourceIndex: number, preference: ReaderVariantPreference,
      result: ReaderVariantSelectionResult) => void) | null = null) {
    this.fallback = new ReaderVariantPreference(fallback.variant, fallback.identity)
    this.revision = revision
    this.resolver = resolver
    this.onSelection = onSelection
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
