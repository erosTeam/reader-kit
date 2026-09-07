import { ReaderAsset, ReaderAssetKind, ReaderAssetProvider, ReaderCancellation, ReaderPage } from '@reader-kit/core'

/** Explicit Debug-lab probe. One missing URI exercises native decode failure, not transport failure. */
export class ReaderLabAssetProbe implements ReaderAssetProvider {
  cancellationMode: 'consumer-only' | 'transport'
  informationSupported: boolean
  private provider: ReaderAssetProvider
  private thumbnailIndex: number
  private injected: boolean = false

  constructor(provider: ReaderAssetProvider, thumbnailIndex: number) {
    this.provider = provider
    this.thumbnailIndex = thumbnailIndex
    this.cancellationMode = provider.cancellationMode
    this.informationSupported = provider.informationSupported === true
  }

  async load(page: ReaderPage, kind: ReaderAssetKind, cancellation: ReaderCancellation,
    forceReload: boolean): Promise<ReaderAsset> {
    cancellation.check()
    if (!this.injected && this.thumbnailIndex >= 0 && kind === 'thumbnail' &&
      page.sourceIndex === this.thumbnailIndex) {
      this.injected = true
      console.info(`[ReaderLabAssetProbe] native_thumbnail_decode_failure source=${page.sourceIndex}`)
      return new ReaderAsset('file:///data/storage/el2/base/cache/rkit-probe-missing-thumbnail')
    }
    return this.provider.load(page, kind, cancellation, forceReload)
  }
}
