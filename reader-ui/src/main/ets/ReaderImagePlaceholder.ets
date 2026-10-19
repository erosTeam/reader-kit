import { ReaderPagedFrame } from '@reader-kit/core'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderLoadingStage } from './ReaderLoadingStage'

/** Image-owned empty-container presentation. Processing cannot reopen it over readable pixels. */
@ComponentV2
export struct ReaderImagePlaceholder {
  @Param frame: ReaderPagedFrame | null = null
  @Param entryTransition: ReaderEntryTransition | null = null

  build() {
    if (this.frame === null || this.frame.asset.needsImagePlaceholder()) {
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
