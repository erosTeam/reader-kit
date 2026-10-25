import { ReaderPagedFrame } from '@reader-kit/core'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderLoadingStage } from './ReaderLoadingStage'

/** Original readiness owns feedback. A thumbnail preview cannot complete its request. */
export class ReaderImagePresentation {
  private readonly phase: 'loading' | 'image' | 'empty'

  get loading(): boolean { return this.phase === 'loading' }
  get pixels(): boolean { return this.phase === 'image' }

  constructor(frame: ReaderPagedFrame | null, decodedOriginalIdentity: string,
    entry: ReaderEntryTransition | null = null) {
    const asset = frame?.asset
    const decoded = frame !== null && asset?.kind === 'original' &&
      (asset.phase === 'decoding' || asset.phase === 'displayed') &&
      asset.assetRequestId > 0 && asset.uri.length > 0 &&
      decodedOriginalIdentity === `${frame.slotId}:${asset.assetRequestId}:` +
        `${frame.part.sourceIndex}:${frame.part.fragment}:${asset.visualRevision}`
    // Core keeps a displayed asset across mode changes, but the new native
    // viewport has not decoded that asset yet (E075). Its own matching receipt
    // ends feedback; a resource's old displayed phase cannot do so. Retained
    // in-place replacements and the entry reveal gate keep their prior rules.
    const awaitingNative = asset?.kind === 'original' && asset.phase === 'displayed' && !decoded
    const awaitingPixels = frame === null || awaitingNative ||
      (asset !== undefined && asset.needsImagePlaceholder() && !decoded) ||
      (frame !== null && entry?.hidesOriginal(frame) === true)
    this.phase = awaitingPixels ? 'loading'
      : asset !== undefined && asset.phase !== 'failed' && asset.phase !== 'suppressed' ? 'image' : 'empty'
  }
}

/** Metadata selects the existing label only; the image owner supplies the display decision. */
@ComponentV2
export struct ReaderImagePlaceholder {
  @Require @Param presentation: ReaderImagePresentation
  @Param frame: ReaderPagedFrame | null = null
  @Param entryTransition: ReaderEntryTransition | null = null

  build() {
    if (this.presentation.loading) {
      ReaderLoadingStage({
        showTransitionBackground: this.frame !== null &&
          this.entryTransition?.hasLoadingBackdrop(this.frame) === true,
        label: this.frame === null || this.frame.asset.phase === 'idle' ? $r('app.string.rkit_loading_resolving')
          : this.frame.asset.phase === 'decoding' ? $r('app.string.rkit_loading_decoding')
            : $r('app.string.rkit_loading_image'),
        loaded: this.frame?.asset.loadProgressLoaded ?? 0,
        total: this.frame?.asset.loadProgressTotal ?? 0,
      })
    }
  }
}
