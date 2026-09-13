import { ReaderAsset, ReaderAssetKind, ReaderAssetProvider, ReaderCancellation, ReaderPage,
  ReaderImageInformation, ReaderImageInformationSource, ReaderOriginalAssetPlan,
  ReaderProcessedAssetVariant, ReaderVariantAssetPlan } from '@reader-kit/core'
import { ReaderFileInformation } from './ReaderFileInformation'

class ReaderLabInformationSource implements ReaderImageInformationSource {
  private readSource: () => Promise<ReaderImageInformation>
  constructor(readSource: () => Promise<ReaderImageInformation>) { this.readSource = readSource }
  read(): Promise<ReaderImageInformation> { return this.readSource() }
}

/** One isolated native decode failure after original resolution; never alters cached files. */
class ReaderLabOriginalPlan implements ReaderOriginalAssetPlan {
  page: ReaderPage
  private plan: ReaderOriginalAssetPlan
  private injected: boolean = false
  constructor(plan: ReaderOriginalAssetPlan) { this.plan = plan; this.page = plan.page.copy() }
  load(cancellation: ReaderCancellation, forceReload: boolean): Promise<ReaderAsset> {
    cancellation.check()
    if (!this.injected) {
      this.injected = true
      return Promise.resolve(new ReaderAsset('file:///data/storage/el2/base/cache/rkit-probe-missing-original-variant'))
    }
    return this.plan.load(cancellation, forceReload)
  }
}

/** Explicit Debug-lab probe. One missing URI exercises native decode failure, not transport failure. */
export class ReaderLabAssetProbe implements ReaderAssetProvider {
  cancellationMode: 'consumer-only' | 'transport'
  informationSupported: boolean
  prepareOriginal?: (page: ReaderPage, cancellation: ReaderCancellation) => Promise<ReaderOriginalAssetPlan>
  prepareVariant?: (page: ReaderPage, variant: ReaderProcessedAssetVariant, identity: string,
    cancellation: ReaderCancellation) => Promise<ReaderVariantAssetPlan>
  private provider: ReaderAssetProvider
  private thumbnailIndex: number
  private injected: boolean = false
  private originalFailureIndex: number
  private originalInjected: boolean = false
  private informationMode: string
  private informationInjected: boolean = false
  private variantInjected: boolean = false

  constructor(provider: ReaderAssetProvider, thumbnailIndex: number, informationMode: string = '',
    originalFailureIndex: number = -1, originalVariantProbe: string = '') {
    this.provider = provider
    this.thumbnailIndex = thumbnailIndex
    this.originalFailureIndex = originalFailureIndex
    this.cancellationMode = provider.cancellationMode
    this.informationSupported = provider.informationSupported === true
    this.informationMode = informationMode
    if (provider.prepareOriginal !== undefined) {
      this.prepareOriginal = (page: ReaderPage, cancellation: ReaderCancellation): Promise<ReaderOriginalAssetPlan> => {
        cancellation.check()
        if (this.provider.prepareOriginal === undefined) throw new Error('reader_original_unavailable')
        if (!this.variantInjected && originalVariantProbe === 'prepare-fail-once') {
          this.variantInjected = true
          return Promise.reject(new Error('reader_lab_original_prepare_failure'))
        }
        if (!this.variantInjected && originalVariantProbe === 'decode-fail-once') {
          this.variantInjected = true
          return this.provider.prepareOriginal(page, cancellation).then((plan: ReaderOriginalAssetPlan): ReaderOriginalAssetPlan => {
            cancellation.check()
            return new ReaderLabOriginalPlan(plan)
          })
        }
        return this.provider.prepareOriginal(page, cancellation)
      }
    }
    if (provider.prepareVariant !== undefined) {
      this.prepareVariant = (page: ReaderPage, variant: ReaderProcessedAssetVariant, identity: string,
        cancellation: ReaderCancellation): Promise<ReaderVariantAssetPlan> => {
        cancellation.check()
        if (this.provider.prepareVariant === undefined) throw new Error('reader_variant_unavailable')
        return this.provider.prepareVariant(page, variant, identity, cancellation)
      }
    }
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
    if (!this.originalInjected && this.originalFailureIndex >= 0 && kind === 'original' &&
      page.sourceIndex === this.originalFailureIndex) {
      this.originalInjected = true
      console.info(`[ReaderLabAssetProbe] native_original_decode_failure source=${page.sourceIndex}`)
      return new ReaderAsset('file:///data/storage/el2/base/cache/rkit-probe-missing-original')
    }
    const asset = await this.provider.load(page, kind, cancellation, forceReload)
    const source = asset.information
    if (kind !== 'original' || source === null ||
      (this.informationMode !== 'fail-once' && this.informationMode !== 'delay-once')) return asset
    const information = new ReaderLabInformationSource((): Promise<ReaderImageInformation> => this.readInformation(source))
    const wrapped = new ReaderAsset(asset.uri, (): void => { asset.release() }, information,
      (): void => { asset.present() })
    wrapped.originalAvailable = asset.originalAvailable
    wrapped.crop = asset.crop
    return wrapped
  }

  private async readInformation(source: ReaderImageInformationSource): Promise<ReaderImageInformation> {
    const inject = !this.informationInjected
    this.informationInjected = true
    if (inject && this.informationMode === 'fail-once') {
      console.info('[ReaderLabAssetProbe] information_header_failure')
      // Exercise a real missing-file header read without deleting or changing the retained image.
      return new ReaderFileInformation('/data/storage/el2/base/cache/rkit-probe-missing-information',
        new ReaderImageInformation()).read()
    }
    const information = await source.read()
    if (inject && this.informationMode === 'delay-once') {
      console.info('[ReaderLabAssetProbe] information_delay')
      await new Promise<void>((resolve): void => { setTimeout(resolve, 3000) })
      console.info('[ReaderLabAssetProbe] information_late_result')
    }
    return information
  }
}
