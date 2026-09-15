import { ReaderLayout } from '@reader-kit/core'
import { ReaderTapAction } from './ReaderTapAction'
import { ReaderTapZonePreviewRegion } from './ReaderTapZonePreviewRegion'

/**
 * Host-owned tap-zone capability.
 *
 * The host keeps preference and layout semantics. reader-kit receives one
 * immutable resolver/presentation snapshot instead of three independently
 * changing inputs.
 */
export class ReaderTapPolicy {
  readonly previewRevision: number
  private readonly resolver: ((xFraction: number, yFraction: number,
    layout: ReaderLayout) => ReaderTapAction) | null
  private readonly preview: ReaderTapZonePreviewRegion[]

  constructor(resolver: ((xFraction: number, yFraction: number,
    layout: ReaderLayout) => ReaderTapAction) | null = null,
    preview: ReaderTapZonePreviewRegion[] = [], previewRevision: number = 0) {
    this.resolver = resolver
    this.preview = preview.map((region: ReaderTapZonePreviewRegion): ReaderTapZonePreviewRegion =>
      new ReaderTapZonePreviewRegion(region.action, region.left, region.top, region.right, region.bottom))
    this.previewRevision = Number.isSafeInteger(previewRevision) && previewRevision > 0 ? previewRevision : 0
  }

  resolve(xFraction: number, yFraction: number, layout: ReaderLayout): ReaderTapAction | null {
    return this.resolver?.(xFraction, yFraction, layout) ?? null
  }

  previewRegions(): ReaderTapZonePreviewRegion[] {
    return this.preview.map((region: ReaderTapZonePreviewRegion): ReaderTapZonePreviewRegion =>
      new ReaderTapZonePreviewRegion(region.action, region.left, region.top, region.right, region.bottom))
  }
}
