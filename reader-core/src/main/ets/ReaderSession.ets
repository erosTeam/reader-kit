import { ReaderUnitKey, ReaderUnit, ReaderPage } from './ReaderContent'
import { ReaderReadingAnchor } from './ReaderDisplayMap'
import { ReaderImageInformation, ReaderImageInformationSource } from './ReaderImageInformation'
import { ReaderImageCropBounds, ReaderImageCropSource } from './ReaderImageCrop'
export { ReaderUnitKey, ReaderUnit, ReaderPage, ReaderThumbnail } from './ReaderContent'

export type ReaderAssetKind = 'original' | 'thumbnail'
/** Body-image quality is independent from the existing body/thumbnail kind. */
export type ReaderAssetVariant = 'default' | 'original' | 'enhanced' | 'translated'
export type ReaderProcessedAssetVariant = 'enhanced' | 'translated'

/** Host policy result for one source page; it carries no service or persistence ownership. */
export class ReaderVariantPreference {
  variant: ReaderProcessedAssetVariant | 'default'
  identity: string

  constructor(variant: ReaderProcessedAssetVariant | 'default' = 'default', identity: string = '') {
    this.variant = variant
    this.identity = variant === 'default' ? '' : identity
  }
}
export type ReaderPhase = 'idle' | 'catalog' | 'asset' | 'decoding' | 'displayed' | 'failed' | 'closed'

/** A consumer cancellation fence; adapters must separately declare transport support. */
export class ReaderCancellation {
  private cancelled: boolean = false
  private listeners: Array<() => void> = []

  cancel(): void {
    if (this.cancelled) return
    this.cancelled = true
    const listeners = this.listeners
    this.listeners = []
    listeners.forEach((listener: () => void): void => {
      try { listener() } catch (_error) {}
    })
  }
  isCancelled(): boolean { return this.cancelled }
  /** Hosts may detach an owned transport or processor immediately; the returned function removes the hook. */
  onCancel(listener: () => void): () => void {
    if (this.cancelled) {
      try { listener() } catch (_error) {}
      return (): void => {}
    }
    this.listeners.push(listener)
    let active: boolean = true
    return (): void => {
      if (!active) return
      active = false
      const index = this.listeners.indexOf(listener)
      if (index >= 0) this.listeners.splice(index, 1)
    }
  }
  check(): void {
    if (this.cancelled) throw new Error('reader_request_cancelled')
  }
}

/**
 * File/URI ownership belongs to the provider. The URI content must remain immutable
 * until release(): ArkUI may keep decoding it after a replacement request begins.
 * Releasing a reader never deletes a host-owned download.
 */
export class ReaderAsset {
  uri: string
  crop: ReaderImageCropSource | null = null
  originalAvailable: boolean = false
  private released: boolean = false
  private releaseResource: () => void
  private presented: boolean = false
  private presentResource: () => void

  information: ReaderImageInformationSource | null

  constructor(uri: string, releaseResource: () => void = () => {},
    information: ReaderImageInformationSource | null = null, presentResource: () => void = () => {}) {
    this.uri = uri
    this.releaseResource = releaseResource
    this.information = information
    this.presentResource = presentResource
  }

  /** Reports the first successful native presentation to the provider. */
  present(): void {
    if (this.released || this.presented) return
    this.presented = true
    this.presentResource()
  }

  release(): void {
    if (this.released) return
    this.released = true
    this.releaseResource()
  }
}

export interface ReaderCatalog {
  open(key: ReaderUnitKey, cancellation: ReaderCancellation): Promise<ReaderUnit>
  page(unit: ReaderUnit, index: number, cancellation: ReaderCancellation): Promise<ReaderPage>
  adjacent(unit: ReaderUnit, direction: 'next' | 'previous'): ReaderUnitKey | null
}

export interface ReaderAssetProvider {
  informationSupported?: boolean
  /** D1 exposes existing service limits instead of claiming detached requests were aborted. */
  cancellationMode: 'consumer-only' | 'transport'
  load(page: ReaderPage, kind: ReaderAssetKind, cancellation: ReaderCancellation, forceReload: boolean): Promise<ReaderAsset>
  /** Resolve only; failure must not replace the currently displayed default image. */
  prepareOriginal?(page: ReaderPage, cancellation: ReaderCancellation): Promise<ReaderOriginalAssetPlan>
  /** Host processing stays outside reader-kit; resolution failure leaves the current body untouched. */
  prepareVariant?(page: ReaderPage, variant: ReaderProcessedAssetVariant, identity: string,
    cancellation: ReaderCancellation): Promise<ReaderVariantAssetPlan>
}

/**
 * Optional host-owned cache warmer. reader-kit selects bounded future source
 * pages, while the host keeps transport, cache lifetime and persistence policy.
 * A successful return is cache readiness only and never presentation evidence.
 */
export interface ReaderPreloadHost {
  preload(page: ReaderPage, cancellation: ReaderCancellation): Promise<void>
}

/** A host-owned resolved recipe, not a downloaded asset or a persistent reader preference. */
export interface ReaderOriginalAssetPlan {
  page: ReaderPage
  variant?: 'original'
  load(cancellation: ReaderCancellation, forceReload: boolean): Promise<ReaderAsset>
}

/** A host-owned, already resolved enhanced or translated recipe for one exact source page. */
export interface ReaderVariantAssetPlan {
  page: ReaderPage
  variant: ReaderProcessedAssetVariant
  /** Exact host processing identity, including every setting that can change the output. */
  identity: string
  load(cancellation: ReaderCancellation, forceReload: boolean): Promise<ReaderAsset>
}

export type ReaderResolvedAssetPlan = ReaderOriginalAssetPlan | ReaderVariantAssetPlan

export class ReaderSnapshot {
  phase: ReaderPhase = 'idle'
  unit: ReaderUnit | null = null
  page: ReaderPage | null = null
  sourceIndex: number = 0
  kind: ReaderAssetKind = 'original'
  variant: ReaderAssetVariant = 'default'
  variantIdentity: string = ''
  originalAvailable: boolean = false
  uri: string = ''
  /** Previous displayed pixels kept below an exact in-place replacement. */
  retainedUri: string = ''
  retainedAssetRequestId: number = 0
  requestId: number = 0
  /** Identity of uri/page, retained while a different unit is only being prepared. */
  assetRequestId: number = 0
  informationAvailable: boolean = false
  error: string = ''
  canPreviousUnit: boolean = false
  canNextUnit: boolean = false
  /** Last UI-observed ORIGINAL, possibly from the previous unit while preparing a new one. */
  presentedAnchor: ReaderReadingAnchor | null = null
  presentedRequestId: number = 0

  copy(): ReaderSnapshot {
    const value = new ReaderSnapshot()
    value.phase = this.phase
    value.unit = this.unit === null ? null : this.unit.copy()
    value.page = this.page === null ? null : this.page.copy()
    value.sourceIndex = this.sourceIndex
    value.kind = this.kind
    value.variant = this.variant
    value.variantIdentity = this.variantIdentity
    value.originalAvailable = this.originalAvailable
    value.uri = this.uri
    value.retainedUri = this.retainedUri
    value.retainedAssetRequestId = this.retainedAssetRequestId
    value.requestId = this.requestId
    value.assetRequestId = this.assetRequestId
    value.informationAvailable = this.informationAvailable
    value.error = this.error
    value.canPreviousUnit = this.canPreviousUnit
    value.canNextUnit = this.canNextUnit
    value.presentedAnchor = this.presentedAnchor === null ? null : this.presentedAnchor.copy()
    value.presentedRequestId = this.presentedRequestId
    return value
  }
}

/**
 * D1 read-only session: deliberately has no settings/progress/tracker persistence port.
 * Commands select content; only a matching native-image callback marks it displayed.
 */
export class ReaderSession {
  private readonly catalog: ReaderCatalog
  private readonly assets: ReaderAssetProvider
  private state: ReaderSnapshot = new ReaderSnapshot()
  private listener: ((snapshot: ReaderSnapshot) => void) | null = null
  private cancellation: ReaderCancellation = new ReaderCancellation()
  private asset: ReaderAsset | null = null
  private retiredAsset: ReaderAsset | null = null
  private originalPlan: ReaderResolvedAssetPlan | null = null
  private epoch: number = 0
  private disposed: boolean = false
  private pendingUnit: ReaderUnitKey | null = null
  private pendingIndex: number = 0
  private viewportActive: boolean = false

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider) {
    this.catalog = catalog
    this.assets = assets
  }

  subscribe(listener: (snapshot: ReaderSnapshot) => void): void {
    this.listener = listener
    listener(this.state.copy())
  }

  snapshot(): ReaderSnapshot { return this.state.copy() }
  async imageCrop(requestId: number): Promise<ReaderImageCropBounds | null> {
    const asset = this.asset
    const eligible = (): boolean => this.current(requestId) && this.state.assetRequestId === requestId &&
      this.asset === asset && this.state.kind === 'original' &&
      (this.state.phase === 'decoding' || this.state.phase === 'displayed')
    if (asset === null || asset.crop === null || !eligible()) return null
    try {
      const bounds = await asset.crop.read()
      return eligible() ? bounds.copy() : null
    } catch (_error) {
      return null
    }
  }
  async imageInformation(requestId: number): Promise<ReaderImageInformation | null> {
    const asset = this.asset
    if (!this.current(requestId) || this.state.phase !== 'displayed' || this.state.kind !== 'original' ||
      this.state.assetRequestId !== requestId || asset?.information === null || asset === null) return null
    try {
      const information = await asset.information.read()
      return this.current(requestId) && this.asset === asset && this.state.phase === 'displayed'
        ? information.copy() : null
    } catch (_error) {
      // Metadata failure is not an image load failure.
      return null
    }
  }
  cancellationMode(): string { return this.assets.cancellationMode }
  setViewportActive(active: boolean): void { this.viewportActive = !this.disposed && active }

  private emit(): void {
    if (this.listener !== null) this.listener(this.state.copy())
  }

  private begin(): number {
    this.cancellation.cancel()
    this.cancellation = new ReaderCancellation()
    this.epoch += 1
    this.state.requestId = this.epoch
    this.state.error = ''
    return this.epoch
  }

  private current(epoch: number): boolean {
    return !this.disposed && epoch === this.epoch
  }

  async open(key: ReaderUnitKey, index: number = 0): Promise<void> {
    if (this.disposed) return
    const epoch = this.begin()
    const cancellation = this.cancellation
    const requestedKey = key.copy()
    this.pendingUnit = requestedKey
    this.pendingIndex = index
    this.state.phase = 'catalog'
    this.emit()
    try {
      const unit = (await this.catalog.open(requestedKey.copy(), cancellation)).copy()
      if (!this.current(epoch)) return
      if (!unit.key.equals(requestedKey) || !Number.isInteger(unit.pageCount) || unit.pageCount < 1) {
        throw new Error('reader_catalog_unavailable')
      }
      this.state.unit = unit
      this.pendingUnit = null
      this.state.canPreviousUnit = this.catalog.adjacent(unit, 'previous') !== null
      this.state.canNextUnit = this.catalog.adjacent(unit, 'next') !== null
      await this.load(unit, this.boundedIndex(index, unit), 'original', epoch, cancellation)
    } catch (_error) {
      this.fail(epoch, 'reader_catalog_failed')
    }
  }

  async show(index: number, kind: ReaderAssetKind = 'original', forceReload: boolean = false,
    assetPlan: ReaderResolvedAssetPlan | null = null): Promise<void> {
    if (this.disposed || this.state.unit === null) return
    const unit = this.state.unit
    this.pendingUnit = null
    const epoch = this.begin()
    await this.load(unit, this.boundedIndex(index, unit), kind, epoch, this.cancellation, forceReload, assetPlan)
  }

  /** Asset slot entry for an already prepared catalog; does not reopen the host unit. */
  async openPrepared(unit: ReaderUnit, index: number, kind: ReaderAssetKind,
    assetPlan: ReaderResolvedAssetPlan | null = null): Promise<void> {
    if (this.disposed) return
    if (!Number.isSafeInteger(unit.pageCount) || unit.pageCount < 1) throw new Error('reader_catalog_unavailable')
    const epoch = this.begin()
    this.pendingUnit = null
    this.state.unit = unit.copy()
    await this.load(this.state.unit, this.boundedIndex(index, unit), kind, epoch, this.cancellation, false, assetPlan)
  }

  async switchUnit(direction: 'next' | 'previous'): Promise<void> {
    if (this.disposed || this.state.unit === null) return
    const target = this.catalog.adjacent(this.state.unit, direction)
    if (target !== null) await this.open(target)
  }

  async retry(): Promise<void> {
    if (this.pendingUnit !== null) {
      await this.open(this.pendingUnit, this.pendingIndex)
    } else {
      await this.show(this.state.sourceIndex, this.state.kind, true, this.originalPlan)
    }
  }

  private boundedIndex(index: number, unit: ReaderUnit): number {
    const safe = Number.isFinite(index) ? Math.floor(index) : 0
    return Math.max(0, Math.min(unit.pageCount - 1, safe))
  }

  private async load(
    unit: ReaderUnit, index: number, kind: ReaderAssetKind,
    epoch: number, cancellation: ReaderCancellation, forceReload: boolean = false,
    assetPlan: ReaderResolvedAssetPlan | null = null,
  ): Promise<void> {
    const retainDisplayed = forceReload && this.state.phase === 'displayed' && this.state.unit !== null &&
      this.state.unit.key.equals(unit.key) && this.state.sourceIndex === index && this.state.kind === kind &&
      this.asset !== null
    this.originalPlan = kind === 'original' ? assetPlan : null
    const variant: ReaderAssetVariant = this.originalPlan?.variant ?? (this.originalPlan === null ? 'default' : 'original')
    const variantIdentity: string = this.originalPlan?.variant === 'enhanced' || this.originalPlan?.variant === 'translated'
      ? this.originalPlan.identity : ''
    if (!retainDisplayed) {
      this.state.phase = 'asset'
      this.state.sourceIndex = index
      this.state.kind = kind
      this.state.variant = variant
      this.state.variantIdentity = variantIdentity
      this.state.originalAvailable = false
      this.state.page = null
      this.state.informationAvailable = false
      this.state.uri = ''
      this.state.retainedUri = ''
      this.state.retainedAssetRequestId = 0
      this.state.assetRequestId = 0
      this.releaseRetiredAsset()
      this.releaseAsset()
      this.emit()
    }
    try {
      const page = (await this.catalog.page(unit.copy(), index, cancellation)).copy()
      if (!this.current(epoch)) return
      if (!page.unit.equals(unit.key) || page.sourceIndex !== index || page.key.length === 0) {
        throw new Error('reader_page_identity_mismatch')
      }
      if (!retainDisplayed) {
        this.state.page = page
        this.emit()
      }
      const plan = this.originalPlan
      if (plan !== null && (!plan.page.unit.equals(page.unit) || plan.page.key !== page.key ||
        plan.page.sourceIndex !== page.sourceIndex)) throw new Error('reader_original_plan_identity_mismatch')
      const asset = plan === null ? await this.assets.load(page.copy(), kind, cancellation, forceReload) :
        await plan.load(cancellation, forceReload)
      if (!this.current(epoch)) {
        asset.release()
        return
      }
      if (asset.uri.length === 0) {
        asset.release()
        throw new Error('reader_empty_asset')
      }
      if (retainDisplayed) {
        // Double-buffer against the most recently displayed native source. A
        // consecutive replacement must retain the source that actually owned
        // the immediately preceding frame, not an older fallback whose Image
        // node has already left the active presentation chain.
        this.releaseRetiredAsset()
        this.retiredAsset = this.asset
        this.state.retainedUri = this.state.uri
        this.state.retainedAssetRequestId = this.state.assetRequestId
      }
      this.asset = asset
      this.state.sourceIndex = index
      this.state.kind = kind
      this.state.variant = variant
      this.state.variantIdentity = variantIdentity
      this.state.page = page
      this.state.uri = asset.uri
      this.state.informationAvailable = asset.information !== null
      this.state.originalAvailable = this.state.variant === 'original' || asset.originalAvailable
      this.state.assetRequestId = epoch
      this.state.phase = 'decoding'
      this.emit()
    } catch (_error) {
      this.fail(epoch, 'reader_asset_failed')
    }
  }

  reportPresentation(requestId: number, success: boolean): void {
    if (!this.current(requestId) || requestId !== this.state.assetRequestId || this.state.phase !== 'decoding') return
    if (success) {
      this.asset?.present()
      // The candidate has survived one composed frame. Retire the fallback now
      // so the cell returns to its single stable Image site before another
      // exact reload; otherwise the conditional candidate site is reused and
      // ArkUI can compose an empty second replacement for the same page.
      this.releaseRetiredAsset()
      this.state.retainedUri = ''
      this.state.retainedAssetRequestId = 0
    }
    this.state.phase = success ? 'displayed' : 'failed'
    this.state.error = success ? '' : 'reader_decode_failed'
    if (!success) {
      this.releaseRetiredAsset()
      this.state.retainedUri = ''
      this.state.retainedAssetRequestId = 0
    }
    this.emit()
  }

  /** A current viewport node can fail while reusing an already decoded asset. */
  reportRenderFailure(requestId: number): void {
    if (!this.current(requestId) || requestId !== this.state.assetRequestId ||
      (this.state.phase !== 'displayed' && this.state.phase !== 'decoding')) return
    this.state.phase = 'failed'
    this.state.error = 'reader_decode_failed'
    this.releaseRetiredAsset()
    this.state.retainedUri = ''
    this.state.retainedAssetRequestId = 0
    this.emit()
  }

  /**
   * Single-original viewport observation, separate from asset/decode completion.
   * D1's contain surface reports its fully visible original at top-center.
   * This is an in-memory observation only, not persistence or unit completion.
   */
  reportVisiblePosition(requestId: number, pageKey: string, x: number, y: number): void {
    const page = this.state.page
    if (!this.viewportActive || !this.current(requestId) || requestId !== this.state.assetRequestId ||
      this.state.phase !== 'displayed' || this.state.kind !== 'original' ||
      page === null || page.key !== pageKey || !Number.isFinite(x) || !Number.isFinite(y) ||
      x < 0 || x > 1 || y < 0 || y > 1) return
    const previous = this.state.presentedAnchor
    if (this.state.presentedRequestId === requestId && previous !== null && previous.x === x && previous.y === y) return
    this.state.presentedAnchor = new ReaderReadingAnchor(page.unit, page.key, page.sourceIndex, x, y)
    this.state.presentedRequestId = requestId
    this.emit()
  }

  private fail(epoch: number, code: string): void {
    if (!this.current(epoch)) return
    this.state.phase = 'failed'
    this.state.error = code
    this.emit()
  }

  private releaseAsset(): void {
    if (this.asset !== null) this.asset.release()
    this.asset = null
  }

  private releaseRetiredAsset(): void {
    if (this.retiredAsset !== null) this.retiredAsset.release()
    this.retiredAsset = null
  }

  close(): void {
    if (this.disposed) return
    this.disposed = true
    this.viewportActive = false
    this.cancellation.cancel()
    this.epoch += 1
    this.releaseRetiredAsset()
    this.releaseAsset()
    this.originalPlan = null
    this.state.phase = 'closed'
    this.state.informationAvailable = false
    this.state.uri = ''
    this.state.retainedUri = ''
    this.state.retainedAssetRequestId = 0
    this.state.assetRequestId = 0
    this.emit()
    this.listener = null
  }
}
