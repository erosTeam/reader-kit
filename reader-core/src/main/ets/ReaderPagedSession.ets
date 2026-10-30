import { ReaderUnitKey, ReaderUnit, ReaderPage } from './ReaderContent'
import {
  ReaderSession, ReaderSnapshot, ReaderCatalog, ReaderAssetProvider, ReaderAssetKind, ReaderAssetVariant,
  ReaderCancellation, ReaderProcessedAssetVariant, ReaderVariantPreference, ReaderPreloadHost, ReaderAutoReadSourceHost,
  ReaderResolvedAssetPlan, ReaderVariantAssetPlan,
  ReaderAssetFailureClassifier,
} from './ReaderSession'
import { ReaderDisplayMap, ReaderDisplayPolicy, ReaderDisplayPart, ReaderReadingAnchor, ReaderFragment,
  readerPolicyRotatesPage } from './ReaderDisplayMap'
import { ReaderThumbnailWindow } from './ReaderThumbnailWindow'
import { ReaderImageInformation } from './ReaderImageInformation'
import { ReaderImageCropBounds } from './ReaderImageCrop'
import { ReaderProcessingCoordinator, ReaderProcessingPolicy, ReaderProcessingState } from './ReaderProcessingCoordinator'

export class ReaderPagedFrame {
  cropPending: boolean = false
  slotId: number
  part: ReaderDisplayPart
  asset: ReaderSnapshot
  crop: ReaderImageCropBounds

  constructor(slotId: number, part: ReaderDisplayPart, asset: ReaderSnapshot,
    crop: ReaderImageCropBounds = new ReaderImageCropBounds()) {
    this.slotId = slotId
    this.part = part.copy()
    this.asset = asset.copy()
    this.crop = crop.copy()
  }
}

/** Exact displayed content ratio, including split, crop and wide-page rotation. */
export function readerPagedFrameAspectRatio(frame: ReaderPagedFrame,
  policy: ReaderDisplayPolicy | null = null): number {
  const page = frame.asset.page
  const useWholePagePreview = frame.asset.kind === 'original' && frame.part.fragment === 'whole' &&
    !frame.crop.applied() && page?.hasWholePagePreviewGeometry() === true &&
    ((page?.width ?? 0) <= 0 || (page?.height ?? 0) <= 0)
  const width = frame.asset.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 :
    useWholePagePreview ? page?.previewWidth ?? 0 : page?.width ?? 0
  const height = frame.asset.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 :
    useWholePagePreview ? page?.previewHeight ?? 0 : page?.height ?? 0
  const region = frame.crop.region(frame.part)
  const fraction = frame.asset.kind === 'original' ? region.width / region.height : 1
  if (policy !== null && frame.part.fragment === 'whole' && readerPolicyRotatesPage(policy, page)) {
    const ratio = width > 0 && height > 0 ? width / height * fraction : 0
    return ratio > 0 ? 1 / ratio : 0
  }
  // Zero means unknown; a loading placeholder is not image geometry.
  return width > 0 && height > 0 ? width / height * fraction : 0
}

export class ReaderPageCropMetadata {
  sourceIndex: number
  bounds: ReaderImageCropBounds
  constructor(sourceIndex: number, bounds: ReaderImageCropBounds) {
    this.sourceIndex = sourceIndex; this.bounds = bounds.copy()
  }
}

export class ReaderPagedItemSnapshot {
  key: string
  index: number
  frames: ReaderPagedFrame[]
  constructor(key: string, index: number, frames: ReaderPagedFrame[]) {
    this.key = key
    this.index = index
    this.frames = frames
  }
}

/** Native-visible decoded originals only; persistence policy remains host-owned. */
export class ReaderObservedPosition {
  anchor: ReaderReadingAnchor
  displayedSourceIndexes: number[]
  pageCount: number
  terminalSourceDisplayed: boolean

  constructor(anchor: ReaderReadingAnchor, displayedSourceIndexes: number[], pageCount: number) {
    this.anchor = anchor.copy()
    this.displayedSourceIndexes = displayedSourceIndexes.slice().sort((left: number, right: number): number => left - right)
    this.pageCount = pageCount
    this.terminalSourceDisplayed = pageCount > 0 && this.displayedSourceIndexes.includes(pageCount - 1)
  }

  copy(): ReaderObservedPosition {
    return new ReaderObservedPosition(this.anchor, this.displayedSourceIndexes, this.pageCount)
  }
}

export class ReaderPagedSnapshot {
  nativeCacheDepth: number = 1
  unit: ReaderUnit | null = null
  phase: 'idle' | 'catalog' | 'ready' | 'failed' | 'closed' = 'idle'
  error: string = ''
  policy: ReaderDisplayPolicy = new ReaderDisplayPolicy()
  kind: ReaderAssetKind = 'original'
  originalPreparing: boolean = false
  variantPreparing: boolean = false
  preparingSourceIndexes: number[] = []
  preparingVariants: ReaderAssetVariant[] = []
  processingStates: ReaderProcessingState[] = []
  cropEnabled: boolean = false
  displayIndex: number = 0
  displayCount: number = 0
  canShiftSpread: boolean = false
  selectionId: number = 0
  /** The commanded/restored location is not evidence that its pixels were seen. */
  anchor: ReaderReadingAnchor | null = null
  observedAnchor: ReaderReadingAnchor | null = null
  observedSelectionId: number = 0
  frames: ReaderPagedFrame[] = []
  /** Render-only item identities, scoped to topologyRevision; never persistent page keys. */
  displayKeys: string[] = []
  topologyRevision: number = 0
  navigationRevision: number = 0
  /** Actual native-visible display range. Prefetch neighbors are excluded. */
  visibleDisplayStart: number = -1
  visibleDisplayEnd: number = -1
  window: ReaderPagedItemSnapshot[] = []
  /** Geometry metadata may outlive an evicted asset; it is never an image lease. */
  pageMetadata: ReaderPage[] = []
  cropMetadata: ReaderPageCropMetadata[] = []
  /** Native pager projection; displayIndex/count remain chapter-local. */
  pagerIndex: number = 0
  pagerKeys: string[] = []
  pagerWindow: ReaderPagedItemSnapshot[] = []
  /** A List position is independent from the selected chapter's source-page index. */
  continuousIndex: number = 0
  continuousPages: Array<ReaderPage | null> = []
  continuousCrops: ReaderImageCropBounds[] = []

  continuousPage(index: number): ReaderPage | null {
    return this.continuousPages[index]?.copy() ?? null
  }
  continuousCrop(index: number): ReaderImageCropBounds {
    return this.continuousCrops[index]?.copy() ?? new ReaderImageCropBounds()
  }
  cropForPage(index: number): ReaderImageCropBounds {
    return this.cropMetadata.find((value: ReaderPageCropMetadata) => value.sourceIndex === index)?.bounds.copy()
      ?? new ReaderImageCropBounds()
  }
  canPreviousUnit: boolean = false
  canNextUnit: boolean = false

  isPreparingVariant(sourceIndex: number, variant: ReaderAssetVariant): boolean {
    for (let index: number = 0; index < this.preparingSourceIndexes.length; index++) {
      if (this.preparingSourceIndexes[index] === sourceIndex && this.preparingVariants[index] === variant) return true
    }
    const processing = this.processingStates.find((value: ReaderProcessingState): boolean =>
      value.sourceIndex === sourceIndex && value.preference.variant === variant)
    if (processing === undefined || processing.phase === 'unavailable') return false
    return processing.phase === 'preparing' || !this.frames.some((frame: ReaderPagedFrame): boolean =>
      frame.part.sourceIndex === sourceIndex && frame.asset.phase === 'displayed' &&
      frame.asset.variant === variant && frame.asset.variantIdentity === processing.preference.identity)
  }

  observedPosition(): ReaderObservedPosition | null {
    const anchor = this.observedAnchor
    if (this.phase !== 'ready' || this.unit === null || anchor === null ||
      this.observedSelectionId !== this.selectionId || !this.unit.key.equals(anchor.unit)) return null
    let frames: ReaderPagedFrame[] = this.frames
    if (this.policy.layout === 'continuous') {
      frames = []
      this.window.forEach((item: ReaderPagedItemSnapshot): void => {
        if (item.index < this.visibleDisplayStart || item.index > this.visibleDisplayEnd) return
        item.frames.forEach((frame: ReaderPagedFrame): void => { frames.push(frame) })
      })
    }
    const indexes: number[] = []
    frames.forEach((frame: ReaderPagedFrame): void => {
      if (frame.asset.kind !== 'original' || frame.asset.phase !== 'displayed' ||
        frame.asset.page?.key !== frame.part.pageKey || !frame.part.unit.equals(this.unit!.key) ||
        indexes.includes(frame.part.sourceIndex)) return
      indexes.push(frame.part.sourceIndex)
    })
    if (!indexes.includes(anchor.sourceIndexHint)) return null
    return new ReaderObservedPosition(anchor, indexes, this.unit.pageCount)
  }

  /** A cached item's render projection, not a second selection or observed anchor. */
  forItem(key: string): ReaderPagedSnapshot {
    const value = new ReaderPagedSnapshot()
    value.unit = this.unit?.copy() ?? null
    value.nativeCacheDepth = this.nativeCacheDepth
    value.phase = this.phase
    value.policy = this.policy.copy()
    value.kind = this.kind
    value.originalPreparing = this.originalPreparing
    value.variantPreparing = this.variantPreparing
    value.preparingSourceIndexes = this.preparingSourceIndexes.slice()
    value.preparingVariants = this.preparingVariants.slice()
    value.processingStates = this.processingStates.slice()
    value.cropEnabled = this.cropEnabled
    value.displayIndex = this.policy.layout === 'continuous' ? this.displayKeys.indexOf(key) :
      this.pagerKeys.indexOf(key) >= 0 ? this.pagerKeys.indexOf(key) : this.displayKeys.indexOf(key)
    value.displayCount = this.displayCount
    value.selectionId = this.selectionId
    value.anchor = this.anchor?.copy() ?? null
    value.topologyRevision = this.topologyRevision
    value.navigationRevision = this.navigationRevision
    value.visibleDisplayStart = this.visibleDisplayStart
    value.visibleDisplayEnd = this.visibleDisplayEnd
    value.frames = ((this.policy.layout === 'continuous' ? this.window : this.pagerWindow)
      .find((item: ReaderPagedItemSnapshot) => item.key === key)?.frames ??
      this.window.find((item: ReaderPagedItemSnapshot) => item.key === key)?.frames ?? [])
      .map((frame: ReaderPagedFrame) => {
        const copy = new ReaderPagedFrame(frame.slotId, frame.part, frame.asset, frame.crop)
        copy.cropPending = frame.cropPending
        return copy
      })
    return value
  }
}

class ReaderPageSlot {
  cropRequestId: number = 0
  cropRevision: number = 0
  crop: ReaderImageCropBounds | null = null
  cropSettled: boolean = false
  id: number
  index: number
  kind: ReaderAssetKind
  session: ReaderSession
  assetPlan: ReaderResolvedAssetPlan | null
  unit: ReaderUnit | null = null

  constructor(id: number, index: number, kind: ReaderAssetKind, session: ReaderSession,
    assetPlan: ReaderResolvedAssetPlan | null = null) {
    this.id = id
    this.index = index
    this.kind = kind
    this.session = session
    this.assetPlan = assetPlan
  }
}

class ReaderWindowUnit {
  unit: ReaderUnit
  pages: Map<number, ReaderPage> = new Map()
  crops: Map<number, ReaderImageCropBounds> = new Map()
  plans: Map<number, ReaderResolvedAssetPlan> = new Map()
  processing: ReaderProcessingCoordinator
  map: ReaderDisplayMap | null = null
  constructor(unit: ReaderUnit, processing: ReaderProcessingCoordinator) {
    this.unit = unit.copy(); this.processing = processing
  }
}

class ReaderContinuousRow {
  context: ReaderWindowUnit
  index: number
  key: string
  constructor(context: ReaderWindowUnit, index: number) {
    this.context = context; this.index = index
    const key = context.unit.key
    this.key = JSON.stringify([key.scope, key.work, key.unit, index])
  }
}

/** A native item references a real chapter-local display map. No spread spans chapters. */
class ReaderPagerRow {
  context: ReaderWindowUnit
  index: number
  key: string
  constructor(context: ReaderWindowUnit, index: number) {
    this.context = context; this.index = index
    const unit = context.unit.key
    this.key = (context.map?.item(index)?.parts ?? []).map((part: ReaderDisplayPart): string =>
      encodeURIComponent(JSON.stringify([unit.scope, unit.work, unit.unit, part.sourceIndex, part.fragment]))).join('+')
  }
}

/**
 * One display/anchor owner. Selected-only uses at most two asset slots; the
 * paged neighbor window uses at most six, plus a temporarily retained outgoing
 * display item during a position handoff. Continuous demand uses the visible
 * range plus its immediate neighbors. ReaderSession continues to
 * own each request, decoder fence and lease; hosts still own chapter semantics.
 * Metadata is discovered only within the requested window, never by opening every page.
 */
export class ReaderPagedSession {
  private readonly catalog: ReaderCatalog
  private readonly assets: ReaderAssetProvider
  private readonly preloadHost: ReaderPreloadHost | null
  private readonly autoReadSourceHost: ReaderAutoReadSourceHost | null
  private processing: ReaderProcessingCoordinator
  private futureProcessing: Map<string, ReaderProcessingCoordinator> = new Map()
  private processingPolicy: ReaderProcessingPolicy | null = null
  private processingAllowed: boolean = true
  private processingCropRevision: string = ''
  private processingReloads: Set<number> = new Set()
  private readonly failures: ReaderAssetFailureClassifier | null
  private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  private map: ReaderDisplayMap | null = null
  private pages: Map<number, ReaderPage> = new Map()
  private cropPages: Map<number, ReaderImageCropBounds> = new Map()
  private slots: ReaderPageSlot[] = []
  private windowUnits: ReaderWindowUnit[] = []
  private continuousRows: ReaderContinuousRow[] = []
  private pagerRows: ReaderPagerRow[] = []
  private continuousProcessingUnits: ReaderWindowUnit[] = []
  private continuousCatalogTasks: Set<string> = new Set()
  private continuousCatalogCancellation: ReaderCancellation = new ReaderCancellation()
  private reconcileDepth: number = 0
  /** Requested native window plus at most one already-leased reverse edge. */
  private resourceWindowIndexes: number[] = []
  private assetPlans: Map<number, ReaderResolvedAssetPlan> = new Map()
  private originalPreparations: Map<number, ReaderCancellation> = new Map()
  private preparationVariants: Map<number, ReaderAssetVariant> = new Map()
  private prefetchNeighbors: boolean = false
  private preloadDepth: number = 0
  private pagedPreloadDepth: number | null = null
  private preloadEpoch: number = 0
  private preloadSignature: string = ''
  private preloadCancellation: ReaderCancellation = new ReaderCancellation()
  private nextUnitPreloadSignature: string = ''
  private nextUnitPreloadCancellation: ReaderCancellation = new ReaderCancellation()
  private autoReadSourcePreparations: Map<number, ReaderCancellation> = new Map()
  /** Retires source preparations even when navigation returns to the same target index. */
  private autoReadSourceGeneration: number = 0
  private displayKeys: string[] = []
  /** Last observed paged item, kept leased until the new selection is visible. */
  private outgoingPositionKey: string | null = null
  private topologySignature: string = ''
  private topologyRevision: number = 0
  private navigationRevision: number = 0
  // Resource preparation follows native motion without committing a reading position.
  private pagedTargetIndex: number = -1
  private pagedTargetTopology: number = -1
  private pagedTargetNavigation: number = -1
  private continuousStart: number = -1
  private continuousEnd: number = -1
  private slotSerial: number = 0
  private epoch: number = 0
  private cancellation: ReaderCancellation = new ReaderCancellation()
  private pendingUnit: ReaderUnitKey | null = null
  private pendingIndex: number = 0
  private disposed: boolean = false
  private active: boolean = false
  private cropEnabled: boolean = false
  private cropPresentationDeferred: boolean = false
  private activityEpoch: number = 0
  private listener: ((snapshot: ReaderPagedSnapshot) => void) | null = null
  private positionListener: ((anchor: ReaderReadingAnchor, selectionId: number) => void) | null = null

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider, preloadHost: ReaderPreloadHost | null = null,
    failures: ReaderAssetFailureClassifier | null = null, autoReadSourceHost: ReaderAutoReadSourceHost | null = null) {
    this.catalog = catalog
    this.assets = assets
    this.preloadHost = preloadHost
    this.failures = failures
    this.autoReadSourceHost = autoReadSourceHost
    this.processing = this.createProcessingCoordinator()
  }

  cancellationMode(): string { return this.assets.cancellationMode }
  informationSupported(): boolean { return this.assets.informationSupported === true }
  originalSelectionSupported(): boolean { return this.assets.prepareOriginal !== undefined }
  variantSelectionSupported(): boolean { return this.assets.prepareVariant !== undefined }

  /** Runtime presentation only. Does not modify host preferences or source dimensions. */
  setCropEnabled(enabled: boolean): void {
    if (this.disposed || this.cropEnabled === enabled) return
    this.cropEnabled = enabled
    if (enabled) this.slots.forEach((slot: ReaderPageSlot) => this.requestCrop(slot, slot.session.snapshot()))
    this.emit()
  }

  /** Keep an in-flight entry's geometry fixed while detection continues normally. */
  setCropPresentationDeferred(deferred: boolean): void {
    if (this.disposed || this.cropPresentationDeferred === deferred) return
    this.cropPresentationDeferred = deferred
    this.emit()
  }

  /** Host-owned crop inputs changed while the retained image asset stayed the same. */
  refreshCrop(): void {
    if (this.disposed) return
    this.cropPages.clear()
    this.windowUnits.forEach((context: ReaderWindowUnit): void => context.crops.clear())
    this.slots.forEach((slot: ReaderPageSlot): void => {
      slot.cropRevision += 1
      slot.cropRequestId = 0
      slot.crop = null
      slot.cropSettled = false
    })
    if (this.cropEnabled) {
      this.slots.forEach((slot: ReaderPageSlot): void => this.requestCrop(slot, slot.session.snapshot()))
    }
    this.emit()
  }

  private requestCrop(slot: ReaderPageSlot, snapshot: ReaderSnapshot): void {
    if (!this.cropEnabled || snapshot.kind !== 'original' || snapshot.assetRequestId === 0 ||
      (snapshot.phase !== 'decoding' && snapshot.phase !== 'displayed') ||
      slot.cropRequestId === snapshot.assetRequestId) return
    const requestId = snapshot.assetRequestId
    const cropRevision = slot.cropRevision
    slot.cropRequestId = requestId
    slot.crop = null
    slot.cropSettled = false
    void slot.session.imageCrop(requestId).then((crop: ReaderImageCropBounds | null): void => {
      if (this.disposed || !this.slots.includes(slot) || slot.cropRevision !== cropRevision ||
        slot.cropRequestId !== requestId ||
        slot.session.snapshot().assetRequestId !== requestId) return
      slot.crop = crop?.copy() ?? null
      slot.cropSettled = true
      const crops = this.windowUnits.find((context: ReaderWindowUnit): boolean =>
        slot.unit?.key.equals(context.unit.key) === true)?.crops ?? this.cropPages
      crops.set(slot.index, crop?.copy() ?? new ReaderImageCropBounds())
      if (this.cropEnabled) this.emit()
    })
  }

  cancelOriginalPreparations(): void {
    if (this.originalPreparations.size === 0) return
    this.originalPreparations.forEach((cancellation: ReaderCancellation) => cancellation.cancel())
    this.originalPreparations.clear()
    this.preparationVariants.clear()
    this.emit()
  }

  /** Reject in-flight host derivatives without disturbing a canonical/original preparation. */
  cancelProcessedVariantPreparations(sourceIndexes: number[]): void {
    let changed: boolean = false
    sourceIndexes.forEach((sourceIndex: number): void => {
      const variant = this.preparationVariants.get(sourceIndex)
      if (variant !== 'enhanced' && variant !== 'translated') return
      this.originalPreparations.get(sourceIndex)?.cancel()
      this.originalPreparations.delete(sourceIndex)
      this.preparationVariants.delete(sourceIndex)
      changed = true
    })
    if (changed) this.emit()
  }

  /**
   * Keep a displayed default/source asset when its processed replacement is
   * still loading. The parent owns the recipe map, so its matching processed
   * plan must leave with the cancelled child replacement.
   */
  cancelRetainedProcessedVariantReplacements(sourceIndexes: number[]): void {
    let changed: boolean = false
    sourceIndexes.forEach((sourceIndex: number): void => {
      const slot = this.slots.find((candidate: ReaderPageSlot): boolean => candidate.index === sourceIndex &&
        candidate.unit?.key.equals(this.state.unit!.key) === true)
      if (slot === undefined || !slot.session.cancelRetainedProcessedReplacement()) return
      const plan = this.assetPlans.get(sourceIndex)
      if (plan?.variant === 'enhanced' || plan?.variant === 'translated') this.assetPlans.delete(sourceIndex)
      if (slot.assetPlan?.variant === 'enhanced' || slot.assetPlan?.variant === 'translated') slot.assetPlan = null
      this.cropPages.delete(sourceIndex)
      changed = true
    })
    if (!changed) return
    this.state.selectionId += 1
    this.reconcile()
  }

  /** Per-source selection within this reading unit; resolution failure keeps the current asset. */
  async selectOriginal(slotId: number, requestId: number, unit: ReaderUnitKey, navigation: number,
    enabled: boolean): Promise<'changed' | 'unchanged' | 'unavailable' | 'stale'> {
    return this.selectAssetVariant(slotId, requestId, unit, navigation, enabled ? 'original' : 'default')
  }

  /** Apply one host-resolved derivative without moving the logical page or owning the host service. */
  async selectVariant(slotId: number, requestId: number, unit: ReaderUnitKey, navigation: number,
    variant: ReaderProcessedAssetVariant | 'default', identity: string = ''):
    Promise<'changed' | 'unchanged' | 'unavailable' | 'stale'> {
    return this.selectAssetVariant(slotId, requestId, unit, navigation, variant, identity)
  }

  /** Prepare one loaded canonical source through the host provider without moving the reading anchor.
   * Visible targets update in place; neighbor targets remain warm until navigation reaches them.
   */
  async prepareVariantForSource(sourceIndex: number, unit: ReaderUnitKey, navigation: number,
    variant: ReaderProcessedAssetVariant, identity: string):
    Promise<'changed' | 'unchanged' | 'unavailable' | 'stale'> {
    const loadedFrame = (): ReaderPagedFrame | undefined => {
      if (this.disposed || !this.active || this.state.phase !== 'ready' || this.state.kind !== 'original' ||
        this.state.unit === null || !this.state.unit.key.equals(unit) || this.navigationRevision !== navigation) {
        return undefined
      }
      for (const item of this.snapshot().window) {
        const frame = item.frames.find((candidate: ReaderPagedFrame): boolean =>
          candidate.part.sourceIndex === sourceIndex && candidate.part.unit.equals(unit) && candidate.asset.page !== null)
        if (frame !== undefined) return frame
      }
      return undefined
    }
    const frame = loadedFrame()
    if (frame === undefined || frame.asset.page === null) return 'stale'
    if (frame.asset.phase !== 'displayed' || identity.length === 0 || this.assets.prepareVariant === undefined) {
      return 'unavailable'
    }
    const existing = this.assetPlans.get(sourceIndex)
    if (existing?.variant === variant && (existing as ReaderVariantAssetPlan).identity === identity) return 'unchanged'
    const previous = this.originalPreparations.get(sourceIndex)
    previous?.cancel()
    this.originalPreparations.delete(sourceIndex)
    this.preparationVariants.delete(sourceIndex)
    const cancellation = new ReaderCancellation()
    this.originalPreparations.set(sourceIndex, cancellation)
    this.preparationVariants.set(sourceIndex, variant)
    this.emit()
    try {
      const page = frame.asset.page.copy()
      const plan = await this.assets.prepareVariant(page, variant, identity, cancellation)
      if (cancellation.isCancelled() || loadedFrame() === undefined) return 'stale'
      if (!plan.page.unit.equals(page.unit) || plan.page.key !== page.key ||
        plan.page.sourceIndex !== sourceIndex || plan.variant !== variant || plan.identity !== identity) {
        return 'unavailable'
      }
      this.assetPlans.set(sourceIndex, plan)
      this.cropPages.delete(sourceIndex)
      if (this.framesAt(this.state.policy.layout === 'continuous' ? this.continuousSelectedIndex() : this.state.displayIndex).some(
        (candidate: ReaderPagedFrame): boolean => candidate.part.sourceIndex === sourceIndex)) {
        this.state.selectionId += 1
      }
      this.reconcile()
      return 'changed'
    } catch (_error) {
      return cancellation.isCancelled() || loadedFrame() === undefined ? 'stale' : 'unavailable'
    } finally {
      if (this.originalPreparations.get(sourceIndex) === cancellation) {
        this.originalPreparations.delete(sourceIndex)
        this.preparationVariants.delete(sourceIndex)
        this.emit()
      }
    }
  }

  private async selectAssetVariant(slotId: number, requestId: number, unit: ReaderUnitKey, navigation: number,
    variant: ReaderAssetVariant, identity: string = ''): Promise<'changed' | 'unchanged' | 'unavailable' | 'stale'> {
    const currentFrame = (): ReaderPagedFrame | undefined => {
      if (this.disposed || !this.active || this.state.phase !== 'ready' || this.state.kind !== 'original' ||
        this.state.unit === null || !this.state.unit.key.equals(unit) || this.navigationRevision !== navigation) return undefined
      return this.snapshot().frames.find((frame: ReaderPagedFrame) => frame.slotId === slotId &&
        frame.asset.requestId === requestId && frame.asset.page !== null)
    }
    const frame = currentFrame()
    if (frame === undefined || frame.asset.page === null) return 'stale'
    const index = frame.part.sourceIndex
    const previous = this.originalPreparations.get(index)
    previous?.cancel()
    this.originalPreparations.delete(index)
    this.preparationVariants.delete(index)
    if (previous !== undefined) this.emit()
    if (frame.asset.variant === variant &&
      (variant === 'default' || variant === 'original' || frame.asset.variantIdentity === identity)) return 'unchanged'
    if (variant === 'original' && (frame.asset.phase !== 'displayed' || !frame.asset.originalAvailable ||
      this.assets.prepareOriginal === undefined)) return 'unavailable'
    if ((variant === 'enhanced' || variant === 'translated') &&
      (frame.asset.phase !== 'displayed' || identity.length === 0 || this.assets.prepareVariant === undefined)) return 'unavailable'
    const cancellation = new ReaderCancellation()
    this.originalPreparations.set(index, cancellation)
    this.preparationVariants.set(index, variant)
    this.emit()
    try {
      let plan: ReaderResolvedAssetPlan | null = null
      if (variant === 'original' && this.assets.prepareOriginal !== undefined) {
        plan = await this.assets.prepareOriginal(frame.asset.page.copy(), cancellation)
      } else if ((variant === 'enhanced' || variant === 'translated') && this.assets.prepareVariant !== undefined) {
        plan = await this.assets.prepareVariant(frame.asset.page.copy(), variant, identity, cancellation)
      }
      if (cancellation.isCancelled() || currentFrame() === undefined) return 'stale'
      if (plan !== null && (!plan.page.unit.equals(frame.asset.page.unit) || plan.page.key !== frame.asset.page.key ||
        plan.page.sourceIndex !== index || (plan.variant ?? 'original') !== variant ||
        ((variant === 'enhanced' || variant === 'translated') &&
          (plan as ReaderVariantAssetPlan).identity !== identity))) {
        return 'unavailable'
      }
      if (plan === null) this.assetPlans.delete(index)
      else this.assetPlans.set(index, plan)
      this.cropPages.delete(index)
      this.state.selectionId += 1
      this.reconcile()
      return 'changed'
    } catch (_error) {
      return cancellation.isCancelled() || currentFrame() === undefined ? 'stale' : 'unavailable'
    } finally {
      if (this.originalPreparations.get(index) === cancellation) {
        this.originalPreparations.delete(index)
        this.preparationVariants.delete(index)
        this.emit()
      }
    }
  }
  async imageInformation(slotId: number, requestId: number, unit: ReaderUnitKey,
    navigation: number): Promise<ReaderImageInformation | null> {
    const expectedUnit = unit.copy()
    const activity = this.activityEpoch
    const selected = (): boolean => this.active && !this.disposed && this.state.phase === 'ready' &&
      activity === this.activityEpoch && this.state.kind === 'original' && this.state.unit?.key.equals(expectedUnit) === true &&
      this.navigationRevision === navigation && this.framesAt(this.state.policy.layout === 'continuous' ? this.continuousSelectedIndex() : this.state.displayIndex)
        .some((frame: ReaderPagedFrame): boolean => frame.slotId === slotId && frame.asset.assetRequestId === requestId)
    if (!selected()) return null
    const slot = this.slots.find((value: ReaderPageSlot): boolean => value.id === slotId)
    const information = await slot?.session.imageInformation(requestId) ?? null
    return selected() ? information : null
  }
  /** The caller owns and closes the auxiliary preview leases, never reading progress. */
  createThumbnailWindow(): ReaderThumbnailWindow {
    return new ReaderThumbnailWindow(this.catalog, this.assets, this.failures)
  }
  setViewportActive(active: boolean): void {
    const retiredTarget = !active && this.pagedTargetIndex >= 0
    if (!active) this.pagedTargetIndex = -1
    if (!active) this.cancelOriginalPreparations()
    if (!active) this.cancelAutoReadSourcePreparations()
    if (!active) {
      this.continuousCatalogCancellation.cancel()
      this.continuousCatalogCancellation = new ReaderCancellation()
      this.continuousCatalogTasks.clear()
    }
    if (this.active && !active) this.activityEpoch += 1
    this.active = active && !this.disposed
    this.scheduleNextUnitPreload()
    this.syncProcessing()
    if ((retiredTarget || (active && this.state.policy.layout === 'continuous')) &&
      !this.disposed && this.state.phase === 'ready') this.reconcile()
  }
  subscribe(listener: (snapshot: ReaderPagedSnapshot) => void,
    positionListener: ((anchor: ReaderReadingAnchor, selectionId: number) => void) | null = null): void {
    this.listener = listener
    this.positionListener = positionListener
    this.emit()
  }

  snapshot(): ReaderPagedSnapshot {
    const value = new ReaderPagedSnapshot()
    value.unit = this.state.unit?.copy() ?? null
    value.nativeCacheDepth = this.pagedPreloadDepth === null
      ? 1 : this.prefetchNeighbors ? this.nativeNeighborDepth() : 0
    if (this.pagedPreloadDepth !== null && value.nativeCacheDepth > 0 &&
      this.resourceWindowIndexes.some((index: number): boolean =>
        this.nativeWindowDistance(index) === value.nativeCacheDepth + 1)) {
      value.nativeCacheDepth += 1
    }
    value.phase = this.state.phase
    value.canShiftSpread = this.spreadShiftTarget() !== null
    value.error = this.state.error
    value.policy = this.state.policy.copy()
    value.kind = this.state.kind
    value.originalPreparing = Array.from(this.preparationVariants.values())
      .some((variant: ReaderAssetVariant): boolean => variant === 'original')
    value.processingStates = this.processing.states()
    value.variantPreparing = this.originalPreparations.size > 0 ||
      value.processingStates.some((value: ReaderProcessingState): boolean => value.phase === 'preparing')
    this.preparationVariants.forEach((variant: ReaderAssetVariant, sourceIndex: number): void => {
      value.preparingSourceIndexes.push(sourceIndex)
      value.preparingVariants.push(variant)
    })
    value.cropEnabled = this.cropEnabled
    value.displayIndex = this.state.displayIndex
    value.displayCount = this.map?.count() ?? 0
    value.selectionId = this.state.selectionId
    value.anchor = this.state.anchor?.copy() ?? null
    value.observedAnchor = this.state.observedAnchor?.copy() ?? null
    value.observedSelectionId = this.state.observedSelectionId
    value.canPreviousUnit = this.state.canPreviousUnit
    value.canNextUnit = this.state.canNextUnit
    value.topologyRevision = this.topologyRevision
    value.navigationRevision = this.navigationRevision
    value.visibleDisplayStart = this.state.policy.layout === 'continuous' ? this.continuousStart : this.state.displayIndex
    value.visibleDisplayEnd = this.state.policy.layout === 'continuous' ? this.continuousEnd : this.state.displayIndex
    value.displayKeys = this.displayKeys.slice()
    value.pageMetadata = Array.from(this.pages.values()).map((page: ReaderPage) => page.copy())
    if (this.cropEnabled && !this.cropPresentationDeferred && this.state.kind === 'original') {
      this.cropPages.forEach((bounds: ReaderImageCropBounds, index: number) => {
        value.cropMetadata.push(new ReaderPageCropMetadata(index, this.state.policy.layout === 'continuous'
          ? bounds.forContinuousPage(index, this.state.unit?.pageCount ?? 0) : bounds))
      })
    }
    value.continuousIndex = this.continuousSelectedIndex()
    value.continuousPages = this.continuousRows.map((row: ReaderContinuousRow): ReaderPage | null =>
      row.context.pages.get(row.index)?.copy() ?? null)
    value.continuousCrops = this.continuousRows.map((row: ReaderContinuousRow): ReaderImageCropBounds =>
      this.continuousRowCrop(row))
    value.frames = this.framesAt(this.state.policy.layout === 'continuous'
      ? value.continuousIndex : this.state.displayIndex)
    if (this.state.policy.layout === 'continuous') {
      value.window = this.resourceWindowIndexes.map((index: number) =>
        new ReaderPagedItemSnapshot(this.displayKeys[index], index, this.framesAt(index)))
    } else {
      value.pagerIndex = this.pagerSelectedIndex()
      value.pagerKeys = this.pagerRows.map((row: ReaderPagerRow): string => row.key)
      value.pagerWindow = this.resourceWindowIndexes.map((index: number): ReaderPagedItemSnapshot =>
        new ReaderPagedItemSnapshot(this.pagerRows[index].key, index, this.framesForPagerRow(index)))
      value.window = this.resourceWindowIndexes.filter((index: number): boolean =>
        this.pagerRows[index]?.context.unit.key.equals(this.state.unit!.key) === true)
        .map((index: number): ReaderPagedItemSnapshot => {
          const local = this.pagerRows[index].index
          return new ReaderPagedItemSnapshot(this.displayKeys[local], local, this.framesAt(local))
        })
    }
    return value
  }

  private framesAt(index: number): ReaderPagedFrame[] {
    if (this.state.policy.layout === 'continuous') {
      const row = this.continuousRows[index]
      if (row === undefined) return []
      const slot = this.slots.find((candidate: ReaderPageSlot): boolean => candidate.index === row.index &&
        candidate.unit?.key.equals(row.context.unit.key) === true)
      if (slot === undefined) return []
      const asset = slot.session.snapshot()
      const page = row.context.pages.get(row.index)
      if (page !== undefined && asset.page !== null) asset.page = page.copy()
      const part = new ReaderDisplayPart(row.context.unit.key, page?.key ?? null, row.index)
      const frame = new ReaderPagedFrame(slot.id, part, asset, this.continuousRowCrop(row))
      frame.cropPending = this.cropEnabled && !this.cropPresentationDeferred && asset.kind === 'original' &&
        (slot.cropRequestId !== asset.assetRequestId || !slot.cropSettled)
      return [frame]
    }
    const parts = this.map?.item(index)?.visualParts(this.state.policy.direction) ?? []
    return parts.filter((part: ReaderDisplayPart) =>
      this.slots.some((slot: ReaderPageSlot) => slot.index === part.sourceIndex &&
        slot.unit?.key.equals(part.unit) === true))
      .map((part: ReaderDisplayPart): ReaderPagedFrame => {
      const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.index === part.sourceIndex &&
        candidate.unit?.key.equals(part.unit) === true)
      const asset = slot?.session.snapshot() ?? new ReaderSnapshot()
      const page = this.pages.get(part.sourceIndex)
      if (page !== undefined && asset.page !== null) asset.page = page.copy()
      let crop = this.cropEnabled && !this.cropPresentationDeferred && slot?.cropRequestId === asset.assetRequestId
        ? slot?.crop?.copy() ?? new ReaderImageCropBounds() : new ReaderImageCropBounds()
      if (this.state.policy.layout === 'continuous') {
        crop = crop.forContinuousPage(part.sourceIndex, this.state.unit?.pageCount ?? 0)
      }
      const frame = new ReaderPagedFrame(slot?.id ?? 0, part, asset, crop)
      frame.cropPending = this.cropEnabled && !this.cropPresentationDeferred && asset.kind === 'original' &&
        (slot?.cropRequestId !== asset.assetRequestId || slot?.cropSettled !== true)
      return frame
    })
  }

  /** Two-level continuous cache, adopted on 2026-10-26 in Koma's current queue.
   * f260c8a tied five-page transport lookahead to native Image owners; the
   * NextN109 trace showed eight ~78MB pixel caches retiring on the UI thread.
   * Keep only immediate native neighbors in Continuous. Future files/processed
   * results still follow preloadDepth via futurePreloadIndexes/syncProcessing.
   * Paging's leased reverse edge, original quality and loading lifetime stay.
   * Delivery requires the named host motion/load/return evidence; do not change
   * this boundary through a host-specific cache count or image-size workaround.
   */
  private nativeNeighborDepth(): number {
    const depth = this.pagedPreloadDepth ?? 1
    return this.state.policy.layout === 'continuous' ? Math.min(1, depth) : depth
  }

  private nativeWindowDistance(index: number): number {
    if (this.state.policy.layout !== 'continuous' || this.continuousStart < 0) {
      return Math.abs(index - (this.state.policy.layout === 'continuous'
        ? this.continuousSelectedIndex() : this.pagerSelectedIndex()))
    }
    return index < this.continuousStart ? this.continuousStart - index :
      Math.max(0, index - this.continuousEnd)
  }

  private windowIndexes(): number[] {
    if (this.map === null || this.map.count() === 0) return []
    if (this.state.policy.layout === 'continuous' && this.continuousStart >= 0) {
      const indexes: number[] = []
      for (let index = this.continuousStart; index <= this.continuousEnd; index++) indexes.push(index)
      if (this.prefetchNeighbors) {
        const depth = this.nativeNeighborDepth()
        for (let offset = 1; offset <= depth; offset++) {
          if (this.continuousStart - offset >= 0) indexes.push(this.continuousStart - offset)
          if (this.continuousEnd + offset < this.map.count()) indexes.push(this.continuousEnd + offset)
        }
      }
      return indexes
    }
    const selected = this.pagerSelectedIndex()
    const indexes: number[] = [selected]
    if (this.prefetchNeighbors) {
      const depth = this.nativeNeighborDepth()
      for (let offset = 1; offset <= depth; offset++) {
        if (selected - offset >= 0) indexes.push(selected - offset)
        if (selected + offset < this.pagerRows.length) indexes.push(selected + offset)
      }
    }
    if (this.outgoingPositionKey !== null) {
      const outgoing = this.pagerRows.findIndex((row: ReaderPagerRow): boolean => row.key === this.outgoingPositionKey)
      if (outgoing >= 0 && !indexes.includes(outgoing)) indexes.push(outgoing)
    }
    if (this.pagedTargetIndex >= 0 && this.pagedTargetTopology === this.topologyRevision &&
      this.pagedTargetNavigation === this.navigationRevision) {
      const add = (index: number): void => {
        if (index >= 0 && index < this.pagerRows.length && !indexes.includes(index)) indexes.push(index)
      }
      add(this.pagedTargetIndex)
      if (this.prefetchNeighbors) {
        add(this.pagedTargetIndex - 1)
        add(this.pagedTargetIndex + 1)
      }
    }
    return indexes
  }

  /** Preheat an animation destination; selection and observed progress are untouched. */
  preparePagedTarget(index: number, topology: number, navigation: number): boolean {
    if (this.disposed || !this.active || this.state.phase !== 'ready' || this.map === null ||
      this.state.policy.layout === 'continuous' || topology !== this.topologyRevision ||
      navigation !== this.navigationRevision || !Number.isSafeInteger(index) || index < 0 || index >= this.map.count()) return false
    const native = this.pagerRows.findIndex((row: ReaderPagerRow): boolean =>
      row.context.unit.key.equals(this.state.unit!.key) && row.index === index)
    return this.preparePagerTarget(native, topology, navigation)
  }

  preparePagerTarget(index: number, topology: number, navigation: number): boolean {
    if (this.disposed || !this.active || this.state.phase !== 'ready' || this.state.policy.layout === 'continuous' ||
      topology !== this.topologyRevision || navigation !== this.navigationRevision ||
      !Number.isSafeInteger(index) || index < 0 || index >= this.pagerRows.length) return false
    const target = index === this.pagerSelectedIndex() ? -1 : index
    if (target === this.pagedTargetIndex && topology === this.pagedTargetTopology &&
      navigation === this.pagedTargetNavigation) return true
    this.pagedTargetIndex = target
    this.pagedTargetTopology = topology
    this.pagedTargetNavigation = navigation
    this.reconcile()
    return true
  }

  setNeighborPreload(enabled: boolean): void {
    if (this.disposed || enabled === this.prefetchNeighbors) return
    this.prefetchNeighbors = enabled
    if (this.state.phase === 'ready') this.reconcile()
  }

  setPagedPreloadDepth(depth: number): void {
    if (this.disposed) return
    const normalized = Number.isFinite(depth) ? Math.max(0, Math.min(5, Math.round(depth))) : 0
    if (normalized === this.pagedPreloadDepth) return
    this.pagedPreloadDepth = normalized
    if (this.state.phase === 'ready') this.reconcile()
  }

  /**
   * Request up to five future visual destinations from a host-owned cache
   * warmer. This never expands the native render window or owns cached files.
   */
  setPreloadDepth(depth: number): void {
    if (this.disposed) return
    const normalized = Number.isFinite(depth) ? Math.max(0, Math.min(5, Math.round(depth))) : 0
    if (normalized === this.preloadDepth) return
    this.preloadDepth = normalized
    this.schedulePreload()
  }

  private futurePreloadIndexes(): number[] {
    if (this.state.phase !== 'ready' || this.map === null || this.state.unit === null ||
      this.map.count() === 0 || this.preloadDepth <= 0) return []
    const endRow = this.continuousRows[this.continuousEnd]
    const from = this.state.policy.layout === 'continuous' && endRow?.context.unit.key.equals(this.state.unit.key) === true
      ? endRow.index + 1 : this.state.displayIndex + 1
    const indexes: number[] = []
    for (let display = from; display < this.map.count() && display < from + this.preloadDepth; display += 1) {
      const parts = this.map.item(display)?.parts ?? []
      parts.forEach((part: ReaderDisplayPart): void => {
        // Continuous reconciliation has already chosen the new live window,
        // but old slots have not retired yet. A retiring slot still inside the
        // file budget needs its existing processing consumer to survive.
        const preparedByWindow = this.pagedPreloadDepth !== null &&
          (this.state.policy.layout === 'continuous'
            ? this.resourceWindowIndexes.some((index: number): boolean =>
              this.continuousRows[index]?.context.unit.key.equals(this.state.unit!.key) === true &&
              this.continuousRows[index]?.index === part.sourceIndex)
            : this.slots.some((slot: ReaderPageSlot): boolean => slot.index === part.sourceIndex &&
              slot.unit?.key.equals(part.unit) === true))
        if (!preparedByWindow && !indexes.includes(part.sourceIndex)) indexes.push(part.sourceIndex)
      })
    }
    return indexes
  }

  /** Hosts publish configuration/permissions; this session owns all preparation consumers. */
  setProcessingPolicy(policy: ReaderProcessingPolicy | null, cropRevision: string = ''): void {
    if (this.disposed) return
    this.processingPolicy = policy; this.processingCropRevision = cropRevision
    if (policy === null) {
      this.processing.clear(); this.retireFutureProcessing()
      this.windowUnits.forEach((context: ReaderWindowUnit): void => context.processing.clear())
    }
    if (this.state.phase === 'ready') this.reconcile()
  }

  setProcessingActive(active: boolean): void {
    if (this.disposed || this.processingAllowed === active) return
    this.processingAllowed = active
    this.scheduleNextUnitPreload()
    this.syncProcessing()
    this.emit()
  }

  private syncProcessing(): void {
    if (this.state.policy.layout === 'continuous' && this.continuousRows.length > 0) {
      this.syncContinuousProcessing(); return
    }
    if (this.pagerRows.length > 0) { this.syncPagerProcessing(); return }
    const unit = this.state.unit
    const policy = this.processingPolicy
    if (unit === null || policy === null || this.state.phase !== 'ready' || this.state.kind !== 'original') {
      this.processing.clear()
      return
    }
    const indexes: number[] = this.futurePreloadIndexes()
    // The continuous candidate's one reverse edge is still a live lease.
    // Keep its file/processed recipe with the native owner across a reversal;
    // excluding it here would retire and re-acquire that very same image.
    const processingWindow = this.state.policy.layout === 'continuous'
      ? this.resourceWindowIndexes : this.windowIndexes()
    processingWindow.forEach((display: number): void => {
      this.map?.item(display)?.parts.forEach((part: ReaderDisplayPart): void => {
        if (!indexes.includes(part.sourceIndex)) indexes.push(part.sourceIndex)
      })
    })
    const current = (this.map?.item(this.state.displayIndex)?.parts ?? [])
      .map((part: ReaderDisplayPart): number => part.sourceIndex)
    const automaticIndex = (this.state.anchor?.sourceIndexHint ?? -2) + 1
    if (policy.automaticNext && automaticIndex >= 0 && automaticIndex < unit.pageCount &&
      !indexes.includes(automaticIndex)) indexes.push(automaticIndex)
    const allowed = indexes.filter((index: number): boolean => !this.processingReloads.has(index) &&
      this.assetPlans.get(index)?.variant !== 'original')
    this.processing.update(unit, allowed, current, automaticIndex, policy,
      this.active && this.processingAllowed, this.cropEnabled, this.processingCropRevision)
  }

  private processingUnitId(key: ReaderUnitKey): string {
    return JSON.stringify([key.scope, key.work, key.unit])
  }

  private createProcessingCoordinator(): ReaderProcessingCoordinator {
    const owner = new ReaderProcessingCoordinator(this.catalog, this.assets, this.preloadHost, (): void => {
      // A future unit can finish preparation without publishing the current unit.
      if (!this.disposed && this.state.phase === 'ready' &&
        (this.processing === owner || this.continuousProcessingUnits.some((context: ReaderWindowUnit): boolean =>
          context.processing === owner))) this.reconcile()
    })
    return owner
  }

  private retireFutureProcessing(keep: Set<string> = new Set<string>()): void {
    this.futureProcessing.forEach((owner: ReaderProcessingCoordinator, id: string): void => {
      if (!keep.has(id)) { this.futureProcessing.delete(id); owner.clear() }
    })
  }

  private stageFutureProcessing(unit: ReaderUnit, indexes: number[], automaticIndex: number): void {
    const policy = this.processingPolicy
    if (policy === null || !this.active || !this.processingAllowed || this.disposed) return
    const id = this.processingUnitId(unit.key)
    let owner = this.futureProcessing.get(id)
    if (owner === undefined) {
      owner = this.createProcessingCoordinator()
      this.futureProcessing.set(id, owner)
    }
    // Do not publish an index-only completion into the current chapter. The
    // prepared owner is promoted when that exact unit becomes the live unit.
    const futurePolicy = new ReaderProcessingPolicy(policy.revision, policy.automaticNext,
      (page: ReaderPage, automatic: boolean): ReaderVariantPreference => policy.preference(page, automatic))
    owner.update(unit, indexes, [], automaticIndex, futurePolicy, true, this.cropEnabled, this.processingCropRevision)
  }

  /** Spend only the remaining page budget after this unit on verified later units.
   * Hosts without verified multi-unit preparation keep their original behavior. */
  private scheduleNextUnitPreload(): void {
    const unit = this.state.unit
    const endRow = this.continuousRows[this.continuousEnd]
    const end = this.state.policy.layout === 'continuous' && endRow?.context.unit.key.equals(unit!.key) === true
      ? endRow.index : this.state.displayIndex
    const lastSource = (this.map?.item(end)?.parts ?? []).reduce(
      (last: number, part: ReaderDisplayPart): number => Math.max(last, part.sourceIndex), -1)
    const remainingHere = unit === null || lastSource < 0 ? this.preloadDepth :
      Math.max(0, unit.pageCount - 1 - lastSource)
    const nextDepth = Math.max(0, this.preloadDepth - remainingHere)
    const eligible = !this.disposed && this.active && this.processingAllowed && this.state.phase === 'ready' &&
      this.state.kind === 'original' && unit !== null && this.map !== null && this.map.count() > 0 &&
      nextDepth > 0 && this.preloadHost?.preloadNextUnit !== undefined
    const signature = !eligible || unit === null ? '' :
      JSON.stringify([unit.key.scope, unit.key.work, unit.key.unit, nextDepth,
        this.processingPolicy?.revision ?? '', this.cropEnabled, this.processingCropRevision])
    if (signature === this.nextUnitPreloadSignature) {
      if (!eligible) this.retireFutureProcessing()
      return
    }
    this.nextUnitPreloadCancellation.cancel()
    this.nextUnitPreloadSignature = signature
    if (signature.length === 0 || unit === null) { this.retireFutureProcessing(); return }
    const cancellation = new ReaderCancellation()
    this.nextUnitPreloadCancellation = cancellation
    const touched: Set<string> = new Set<string>()
    console.info(`[ReaderPreload] next_unit depth=${nextDepth}`)
    const completed = (): void => {
      if (!cancellation.isCancelled() && this.nextUnitPreloadCancellation === cancellation) {
        this.retireFutureProcessing(touched)
      }
    }
    void this.preloadHost?.preloadNextUnit?.(unit.copy(), nextDepth, cancellation,
      (future: ReaderUnit, indexes: number[], precedingPages: number): void => {
        if (cancellation.isCancelled() || this.nextUnitPreloadCancellation !== cancellation ||
          this.state.phase !== 'ready' || this.state.unit?.key.equals(unit.key) !== true) return
        touched.add(this.processingUnitId(future.key))
        this.appendWindowUnit(future)
      }).then(completed, (): void => {
        completed()
        if (!cancellation.isCancelled()) console.warn('[ReaderPreload] next_unit_failed')
      })
  }

  private schedulePreload(): void {
    this.scheduleNextUnitPreload()
    if (this.processingPolicy !== null) {
      this.preloadCancellation.cancel(); this.preloadSignature = ''; return
    }
    const unit = this.state.unit
    const indexes = this.futurePreloadIndexes()
    const signature = unit === null || this.preloadHost === null || indexes.length === 0
      ? '' : JSON.stringify([unit.key.scope, unit.key.work, unit.key.unit, this.topologyRevision,
        this.navigationRevision, this.preloadDepth, indexes])
    if (signature === this.preloadSignature) return
    this.preloadSignature = signature
    this.preloadCancellation.cancel()
    this.preloadCancellation = new ReaderCancellation()
    const cancellation = this.preloadCancellation
    const epoch = ++this.preloadEpoch
    if (signature.length === 0 || unit === null || this.preloadHost === null) return
    const target = unit.copy()
    console.info(`[ReaderPreload] unit=${target.key.scope}:${target.key.work}:${target.key.unit} ` +
      `depth=${this.preloadDepth} sources=${indexes.join(',')}`)
    indexes.forEach((index: number): void => {
      void this.catalog.page(target.copy(), index, cancellation).then((page: ReaderPage): void => {
        if (this.disposed || cancellation.isCancelled() || epoch !== this.preloadEpoch ||
          this.state.unit?.key.equals(target.key) !== true || page.sourceIndex !== index ||
          !page.unit.equals(target.key)) return
        void this.preloadHost?.preload(page.copy(), cancellation).catch((): void => {
          if (!cancellation.isCancelled() && epoch === this.preloadEpoch) {
            console.warn(`[ReaderPreload] failed source=${index}`)
          }
        })
      }).catch((): void => {})
    })
  }

  /**
   * The common auto-read controller calls this only after its dwell expires.
   * It requests just the next logical display item's sources, so a zero normal
   * preload depth still has a real path to body-source readiness.
   */
  requestAutoReadTargetSource(): void {
    const unit = this.state.unit
    if (this.disposed || !this.active || this.autoReadSourceHost === null || unit === null ||
      this.state.phase !== 'ready' || this.map === null) return
    const targetIndex = this.state.displayIndex + 1
    const target = this.map.item(targetIndex)
    if (target === null) return
    const targetUnit = unit.copy()
    const generation = this.autoReadSourceGeneration
    target.parts.forEach((part: ReaderDisplayPart): void => {
      const existing = this.pages.get(part.sourceIndex)
      if (existing?.bodySourceReady === true || existing?.bodySourceFailed === true ||
        this.autoReadSourcePreparations.has(part.sourceIndex)) return
      const cancellation = new ReaderCancellation()
      this.autoReadSourcePreparations.set(part.sourceIndex, cancellation)
      void this.catalog.page(targetUnit.copy(), part.sourceIndex, cancellation).then((page: ReaderPage): Promise<void> | void => {
        if (!this.autoReadSourceCurrent(targetUnit, targetIndex, part.sourceIndex, generation, cancellation) ||
          page.sourceIndex !== part.sourceIndex || !page.unit.equals(targetUnit.key)) return
        this.installAutoReadSourcePage(page)
        if (page.bodySourceReady || page.bodySourceFailed) return
        return this.autoReadSourceHost?.prepareAutoReadSource(page.copy(), cancellation).then((resolved: ReaderPage): void => {
          if (!this.autoReadSourceCurrent(targetUnit, targetIndex, part.sourceIndex, generation, cancellation) ||
            resolved.sourceIndex !== part.sourceIndex || !resolved.unit.equals(targetUnit.key)) return
          this.installAutoReadSourcePage(resolved)
        })
      }).catch((): void => {
        if (!this.autoReadSourceCurrent(targetUnit, targetIndex, part.sourceIndex, generation, cancellation)) return
        const failed = this.pages.get(part.sourceIndex)
        if (failed !== undefined) {
          const value = failed.copy()
          value.bodySourceFailed = true
          this.installAutoReadSourcePage(value)
        }
        console.warn(`[ReaderAutoRead] target_source_failed source=${part.sourceIndex}`)
      }).finally((): void => {
        if (this.autoReadSourcePreparations.get(part.sourceIndex) === cancellation) {
          this.autoReadSourcePreparations.delete(part.sourceIndex)
        }
      })
    })
  }

  private autoReadSourceCurrent(unit: ReaderUnit, targetIndex: number, sourceIndex: number, generation: number,
    cancellation: ReaderCancellation): boolean {
    return !this.disposed && this.active && !cancellation.isCancelled() && generation === this.autoReadSourceGeneration &&
      this.state.phase === 'ready' &&
      this.state.unit?.key.equals(unit.key) === true && this.state.displayIndex + 1 === targetIndex &&
      this.map?.item(targetIndex)?.parts.some((part: ReaderDisplayPart): boolean => part.sourceIndex === sourceIndex) === true
  }

  private installAutoReadSourcePage(page: ReaderPage): void {
    const previous = this.pages.get(page.sourceIndex)
    const value = page.copy()
    if (value.bodySourceReady) value.bodySourceFailed = false
    this.pages.set(page.sourceIndex, value)
    if (previous === undefined) this.rebuild()
    else this.emit()
  }

  /** Stop automatic-target preparation without changing the reader selection. */
  cancelAutoReadSourcePreparations(): void {
    this.autoReadSourceGeneration += 1
    this.autoReadSourcePreparations.forEach((cancellation: ReaderCancellation): void => cancellation.cancel())
    this.autoReadSourcePreparations.clear()
  }

  private emit(): void {
    if (this.reconcileDepth === 0 && this.listener !== null) this.listener(this.snapshot())
  }

  async open(key: ReaderUnitKey, index: number = 0): Promise<void> {
    if (this.disposed) return
    const preparedProcessing = this.windowUnits.find((context: ReaderWindowUnit): boolean =>
      context.unit.key.equals(key) && this.state.unit?.key.equals(key) !== true)?.processing ?? this.futureProcessing.get(this.processingUnitId(key))
    this.clearWindowUnits(preparedProcessing ?? null)
    this.outgoingPositionKey = null
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    if (this.processing !== preparedProcessing) this.processing.clear()
    if (preparedProcessing !== undefined) {
      this.futureProcessing.delete(this.processingUnitId(key))
      this.processing = preparedProcessing
    } else {
      this.retireFutureProcessing()
    }
    this.nextUnitPreloadSignature = ''
    this.nextUnitPreloadCancellation.cancel()
    this.preloadSignature = ''
    this.preloadCancellation.cancel()
    this.preloadCancellation = new ReaderCancellation()
    this.preloadEpoch += 1
    this.cancellation.cancel()
    this.cancellation = new ReaderCancellation()
    const cancellation = this.cancellation
    const epoch = ++this.epoch
    const target = key.copy()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    this.pendingUnit = target
    this.pendingIndex = index
    this.state.phase = 'catalog'
    this.state.error = ''
    this.state.selectionId += 1
    this.emit()
    try {
      const unit = (await this.catalog.open(target.copy(), cancellation)).copy()
      if (this.disposed || epoch !== this.epoch) return
      if (!unit.key.equals(target) || !Number.isSafeInteger(unit.pageCount) || unit.pageCount < 1) {
        throw new Error('reader_catalog_unavailable')
      }
      this.releaseSlots()
      this.assetPlans.clear()
      this.pages.clear()
      this.cropPages.clear()
      this.topologySignature = ''
      this.state.unit = unit
      this.state.kind = 'original'
      this.state.phase = 'ready'
      this.pendingUnit = null
      this.state.canPreviousUnit = this.catalog.adjacent(unit.copy(), 'previous') !== null
      this.state.canNextUnit = this.catalog.adjacent(unit.copy(), 'next') !== null
      this.state.anchor = new ReaderReadingAnchor(unit.key, null,
        Number.isFinite(index) ? Math.max(0, Math.min(unit.pageCount - 1, Math.floor(index))) : 0)
      this.rebuild()
    } catch (_error) {
      if (this.disposed || epoch !== this.epoch) return
      this.state.phase = 'failed'
      this.state.error = 'reader_catalog_failed'
      this.emit()
    }
  }

  setPolicy(policy: ReaderDisplayPolicy): void {
    if (this.disposed) return
    if (!Number.isFinite(policy.widePageRatio) || policy.widePageRatio <= 1) {
      throw new Error('reader_unsupported_paged_policy')
    }
    if (this.state.policy.layout !== policy.layout) {
      // Mode changes preserve the selected real page's lease. Only neighboring
      // chapters leave this surface; paged reconciliation retires those slots.
      if (policy.layout !== 'continuous') {
        const removed = this.slots.filter((slot: ReaderPageSlot): boolean =>
          slot.unit?.key.equals(this.state.unit!.key) !== true)
        this.slots = this.slots.filter((slot: ReaderPageSlot): boolean => !removed.includes(slot))
        removed.forEach((slot: ReaderPageSlot): void => slot.session.close())
      }
      this.clearWindowUnits()
      this.resourceWindowIndexes = []
    }
    this.windowUnits.forEach((context: ReaderWindowUnit): void => { context.map = null })
    this.state.policy = policy.copy()
    this.outgoingPositionKey = null
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    if (this.state.phase === 'ready') this.rebuild()
    else this.emit()
  }

  move(direction: 'next' | 'previous'): void {
    if (this.disposed || this.state.phase !== 'ready' || this.map === null) return
    const next = this.map.neighbor(this.state.displayIndex, direction)
    if (next === null) return
    this.selectDisplay(next, this.topologyRevision, this.navigationRevision)
  }

  private spreadShiftTarget(): number | null {
    if (this.disposed || this.state.phase !== 'ready' || this.state.policy.layout !== 'spread' ||
      this.state.unit === null || this.map === null) return null
    const item = this.map.item(this.state.displayIndex)
    if (item === null || item.parts.length === 0) return null
    const target = item.parts[0].sourceIndex + 1
    return target < this.state.unit.pageCount ? target : null
  }

  /** Advance the logical spread start by one source and re-pair atomically.
   * This is runtime alignment only, never a chapter command or saved progress.
   */
  shiftSpread(unit: ReaderUnitKey, topology: number, navigation: number): boolean {
    const target = this.spreadShiftTarget()
    if (target === null) return false
    const item = this.map === null ? null : this.map.item(this.state.displayIndex)
    if (!this.active || !this.state.unit?.key.equals(unit) || topology !== this.topologyRevision ||
      navigation !== this.navigationRevision || item === null || item.parts.length === 0) return false
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.state.policy = this.state.policy.copy()
    this.outgoingPositionKey = null
    this.navigationRevision += 1
    if (item.parts.length === 1) {
      // Single-cell (the leading alone page): step only the pairing offset and keep
      // the current source page; rebuild() re-resolves the unchanged anchor into the
      // new pair ([1] -> [1,2], page index 0 stays current).
      this.state.policy.firstPageAlone = !this.state.policy.firstPageAlone
    } else {
      this.state.policy.firstPageAlone = target % 2 === 1
      this.state.anchor = new ReaderReadingAnchor(unit, this.pages.get(target)?.key ?? null, target)
    }
    this.rebuild()
    return true
  }

  /** A source-page command, not a display index or an observed/saved reading position.
   * A slider may outlive its unit/navigation; stale commits must not seek the new unit.
   */
  /** Resolve a source page index to its display index under the current spread policy. */
  displayIndexForSource(sourceIndex: number): number | null {
    if (this.map === null || !Number.isSafeInteger(sourceIndex) || sourceIndex < 0 ||
      this.state.unit === null || sourceIndex >= this.state.unit.pageCount) return null
    const count: number = this.map.count()
    for (let displayIndex = 0; displayIndex < count; displayIndex += 1) {
      const item = this.map.item(displayIndex)
      if (item !== null && item.parts.some((part): boolean => part.sourceIndex === sourceIndex)) {
        return displayIndex
      }
    }
    return null
  }

  /** Retain the last observed paged body, not an unpresented intermediate seek. */
  private beginPositionHandoff(): void {
    if (this.state.policy.layout === 'continuous' || this.state.kind !== 'original') {
      this.outgoingPositionKey = null
      return
    }
    if (this.outgoingPositionKey !== null) return
    if (this.state.observedSelectionId !== this.state.selectionId) return
    this.outgoingPositionKey = this.pagerRows[this.pagerSelectedIndex()]?.key ?? null
  }

  /** A source-page command, not a display index or an observed/saved reading position.
   * A slider may outlive its unit/navigation; stale commits must not seek the new unit.
   */
  seekSource(index: number, unit: ReaderUnitKey, navigationRevision: number): boolean {
    if (this.disposed || this.state.phase !== 'ready' || this.state.unit === null ||
      !this.state.unit.key.equals(unit) || navigationRevision !== this.navigationRevision ||
      !Number.isSafeInteger(index) || index < 0 || index >= this.state.unit.pageCount) return false
    this.beginPositionHandoff()
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    // Center/whole resolves to the first physical half in the current direction.
    // Re-seeking the current source intentionally returns to its start.
    this.state.anchor = new ReaderReadingAnchor(unit, this.pages.get(index)?.key ?? null, index)
    this.rebuild()
    return true
  }

  /** Reject a native index from a retired topology or superseded navigation command. */
  selectDisplay(index: number, topologyRevision: number, navigationRevision: number): boolean {
    if (this.disposed || this.state.phase !== 'ready' || this.map === null ||
      topologyRevision !== this.topologyRevision || navigationRevision !== this.navigationRevision ||
      !Number.isInteger(index) || index < 0 || index >= this.map.count()) return false
    if (index === this.state.displayIndex) return true
    this.beginPositionHandoff()
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    this.state.anchor = this.map.anchorAt(index)
    // A native selection changes position, not chapter maps or their keyed row projection.
    this.resolvePosition()
    return true
  }

  setAssetKind(kind: ReaderAssetKind): void {
    if (this.disposed || this.state.phase !== 'ready' || kind === this.state.kind) return
    if (kind === 'thumbnail' && this.snapshot().frames.some((frame: ReaderPagedFrame) =>
      frame.asset.page === null || !frame.asset.page.thumbnail.available)) return
    this.state.kind = kind
    this.outgoingPositionKey = null
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    this.state.selectionId += 1
    this.reconcile()
  }

  async switchUnit(direction: 'next' | 'previous'): Promise<void> {
    if (this.disposed || this.state.unit === null) return
    const target = this.catalog.adjacent(this.state.unit.copy(), direction)
    if (target !== null) await this.open(target)
  }

  /** A host may resolve legacy chapter chronology beside a readable page.
   * Refresh only its neighboring units, retaining current images and position. */
  refreshAdjacency(): void {
    if (this.disposed || this.state.phase !== 'ready' || this.state.unit === null) return
    this.state.canPreviousUnit = this.catalog.adjacent(this.state.unit.copy(), 'previous') !== null
    this.state.canNextUnit = this.catalog.adjacent(this.state.unit.copy(), 'next') !== null
    this.nextUnitPreloadSignature = ''
    this.scheduleNextUnitPreload()
    this.emit()
  }

  async retry(): Promise<void> {
    if (this.disposed) return
    if (this.pendingUnit !== null) await this.open(this.pendingUnit, this.pendingIndex)
    else {
      this.cancelAutoReadSourcePreparations()
      await Promise.all(this.slots.filter((slot: ReaderPageSlot) => slot.session.snapshot().phase === 'failed' &&
        this.map?.item(this.state.displayIndex)?.parts.some((part: ReaderDisplayPart) => part.sourceIndex === slot.index))
        .map((slot: ReaderPageSlot) => slot.session.retry()))
    }
  }

  private localIndexForItemKey(key: string): number {
    if (this.state.policy.layout === 'continuous') return this.displayKeys.indexOf(key)
    const row = this.pagerRows.find((value: ReaderPagerRow): boolean => value.key === key)
    if (row !== undefined) return row.context.unit.key.equals(this.state.unit!.key) ? row.index : -1
    return this.displayKeys.indexOf(key)
  }

  /** Retry one visible failed asset without selecting it or reopening its host unit. */
  async retryItem(topologyRevision: number, itemKey: string, slotId: number, requestId: number): Promise<boolean> {
    if (this.disposed || !this.active || this.state.phase !== 'ready' || topologyRevision !== this.topologyRevision) return false
    const index = this.localIndexForItemKey(itemKey)
    const visible = this.state.policy.layout === 'continuous'
      ? this.continuousStart >= 0 && index >= this.continuousStart && index <= this.continuousEnd
      : index === this.state.displayIndex
    if (!visible) return false
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame) => candidate.slotId === slotId &&
      candidate.asset.requestId === requestId && candidate.asset.phase === 'failed')
    const slot = frame === undefined ? undefined : this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (slot === undefined) return false
    this.cancelAutoReadSourcePreparations()
    await slot.session.retry()
    return true
  }

  /** Run one provider-owned action for an exact visible suppressed asset, then let its slot reload itself. */
  async resolveNoticeItem(topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, noticeId: string): Promise<boolean> {
    if (this.disposed || !this.active || this.state.phase !== 'ready' ||
      topologyRevision !== this.topologyRevision || navigationRevision !== this.navigationRevision) return false
    const index = this.localIndexForItemKey(itemKey)
    const visible = this.state.policy.layout === 'continuous'
      ? this.continuousStart >= 0 && index >= this.continuousStart && index <= this.continuousEnd
      : index === this.state.displayIndex
    if (!visible) return false
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame) => candidate.slotId === slotId &&
      candidate.asset.requestId === requestId && candidate.asset.assetRequestId === requestId &&
      candidate.asset.phase === 'suppressed' && candidate.asset.notice?.id === noticeId)
    const slot = frame === undefined ? undefined : this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    return await slot?.session.resolveNotice(requestId, noticeId) ?? false
  }

  /** Force-reload one exact visible source. Processed variants return to the refreshed source first;
   * the surface may then re-apply its current host-owned variant preference.
   */
  async reloadItem(topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number): Promise<boolean> {
    if (this.disposed || !this.active || this.state.phase !== 'ready' ||
      topologyRevision !== this.topologyRevision || navigationRevision !== this.navigationRevision) return false
    const index = this.localIndexForItemKey(itemKey)
    const visible = this.state.policy.layout === 'continuous'
      ? this.continuousStart >= 0 && index >= this.continuousStart && index <= this.continuousEnd
      : index === this.state.displayIndex
    if (!visible) return false
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame) => candidate.slotId === slotId &&
      candidate.asset.requestId === requestId && candidate.asset.page !== null &&
      (candidate.asset.phase === 'displayed' || candidate.asset.phase === 'failed'))
    const slot = frame === undefined ? undefined : this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (slot === undefined) return false
    const keepOriginal = frame?.asset.variant === 'original' && slot.assetPlan?.variant === 'original'
    if (!keepOriginal) {
      this.assetPlans.delete(slot.index)
      slot.assetPlan = null
    }
    this.processingReloads.add(slot.index)
    this.processing.invalidate(slot.index)
    try { await slot.session.show(slot.index, slot.kind, true, slot.assetPlan) }
    finally { this.processingReloads.delete(slot.index); this.reconcile() }
    return true
  }

  private rebuild(): void {
    if (this.state.unit === null || this.state.anchor === null) return
    this.map = new ReaderDisplayMap(this.state.unit, Array.from(this.pages.values()), this.state.policy)
    if (this.state.policy.layout === 'continuous') {
      this.ensureWindowCurrent()
      this.rebuildContinuousRows()
      const signature = `continuous:${this.state.policy.direction}:${this.state.policy.rotateWidePages}`
      if (signature !== this.topologySignature) {
        this.topologySignature = signature
        this.topologyRevision += 1
      }
      this.resolvePosition()
      return
    }
    const keys: string[] = []
    for (let index = 0; index < this.map.count(); index++) {
      keys.push((this.map.item(index)?.parts ?? []).map((part: ReaderDisplayPart) =>
        `${part.sourceIndex}:${part.fragment}`).join('+'))
    }
    const pagingAxis = this.state.policy.pagingAxis
    const signature = `${this.state.policy.layout}:${this.state.policy.direction}:${pagingAxis}:` +
      `${this.state.policy.rotateWidePages}:${this.state.policy.splitWidePages}:${this.state.policy.firstPageAlone}`
    if (signature !== this.topologySignature) {
      this.topologySignature = signature
      this.topologyRevision += 1
      this.displayKeys = keys
    }
    this.displayKeys = keys
    this.ensureWindowCurrent()
    this.rebuildPagerRows()
    this.resolvePosition()
  }

  /** Position changes reuse the current topology; only structural changes rebuild it. */
  private resolvePosition(): void {
    if (this.map === null || this.state.anchor === null) return
    const resolved = this.map.resolve(this.state.anchor)
    if (!resolved.resolved()) {
      this.state.error = 'reader_anchor_unresolved'
      this.state.phase = 'failed'
      this.emit()
      return
    }
    this.state.anchor = resolved.anchor
    this.state.displayIndex = resolved.displayIndex
    if (this.outgoingPositionKey === this.pagerRows[this.pagerSelectedIndex()]?.key ||
      (this.outgoingPositionKey !== null && !this.pagerRows.some((row: ReaderPagerRow): boolean => row.key === this.outgoingPositionKey))) {
      this.outgoingPositionKey = null
    }
    this.state.selectionId += 1
    this.reconcile()
  }

  private reconcile(): void {
    if (this.state.unit === null) return
    // Publish one coherent window after synchronous slot setup. Asset promises
    // keep their existing schedule and publish each later progress/result normally.
    this.reconcileDepth += 1
    try {
      this.reconcileSlots()
    } finally {
      this.reconcileDepth -= 1
      if (this.reconcileDepth === 0) this.emit()
    }
  }

  private reconcileSlots(): void {
    if (this.state.policy.layout === 'continuous') { this.reconcileContinuousSlots(); return }
    const requested = this.windowIndexes()
    const spare = this.prefetchNeighbors && this.pagedPreloadDepth !== null && this.pagedPreloadDepth > 0
      ? this.resourceWindowIndexes.filter((index: number): boolean => !requested.includes(index) &&
        this.nativeWindowDistance(index) <= this.nativeNeighborDepth() + 1).slice(0, 1) : []
    this.resourceWindowIndexes = requested.concat(spare)
    this.syncPagerProcessing()
    const parts: ReaderDisplayPart[] = []
    this.resourceWindowIndexes.forEach((index: number): void => {
      const row = this.pagerRows[index]
      row?.context.map?.item(row.index)?.parts.forEach((part: ReaderDisplayPart): void => {
        if (!parts.some((other: ReaderDisplayPart): boolean => other.unit.equals(part.unit) &&
          other.sourceIndex === part.sourceIndex)) parts.push(part)
      })
    })
    const removed = this.slots.filter((slot: ReaderPageSlot): boolean => slot.kind !== this.state.kind ||
      !parts.some((part: ReaderDisplayPart): boolean => slot.unit?.key.equals(part.unit) === true && slot.index === part.sourceIndex))
    this.slots = this.slots.filter((slot: ReaderPageSlot): boolean => !removed.includes(slot))
    removed.forEach((slot: ReaderPageSlot): void => slot.session.close())
    parts.forEach((part: ReaderDisplayPart): void => {
      const context = this.windowUnits.find((value: ReaderWindowUnit): boolean => value.unit.key.equals(part.unit))
      if (context === undefined) return
      const explicit = context.plans.get(part.sourceIndex) ?? null
      const plan = this.state.kind !== 'original' ? null : explicit?.variant === 'original' || this.processingPolicy === null
        ? explicit : context.processing.plan(part.sourceIndex)
      const existing = this.slots.find((slot: ReaderPageSlot): boolean => slot.unit?.key.equals(part.unit) === true &&
        slot.index === part.sourceIndex)
      if (existing !== undefined) {
        if (existing.assetPlan !== plan) { existing.assetPlan = plan; void existing.session.show(part.sourceIndex, this.state.kind, false, plan) }
        return
      }
      const slot = new ReaderPageSlot(++this.slotSerial, part.sourceIndex, this.state.kind,
        new ReaderSession(this.catalog, this.assets, this.failures), plan)
      slot.unit = context.unit.copy()
      this.slots.push(slot)
      slot.session.subscribe((snapshot: ReaderSnapshot): void => this.slotChanged(slot, snapshot))
      void slot.session.openPrepared(context.unit, part.sourceIndex, slot.kind, plan)
    })
    this.schedulePreload()
    if (this.preloadHost?.preloadNextUnit !== undefined) this.prepareWindowAdjacent()
  }

  private slotChanged(slot: ReaderPageSlot, snapshot: ReaderSnapshot): void {
    if (this.disposed || !this.slots.includes(slot)) return
    // subscribe() echoes the unchanged constructor state before openPrepared.
    // It is not a resource update; reconcile publishes the completed synchronous
    // slot setup once, and later asset progress keeps its normal notifications.
    if (snapshot.phase === 'idle' && snapshot.requestId === 0) return
    this.requestCrop(slot, snapshot)
    if (this.state.policy.layout === 'continuous' || slot.unit?.key.equals(this.state.unit!.key) !== true) {
      if (snapshot.page !== null) this.installWindowPage(slot, snapshot.page)
      this.emit()
      return
    }
    const page = snapshot.page
    const previous = page === null ? undefined : this.pages.get(page.sourceIndex)?.copy()
    if (this.state.phase !== 'ready' || page === null || !this.installSlotPage(page)) {
      this.emit()
      return
    }
    this.publishPageMetadata(previous, this.pages.get(page.sourceIndex) as ReaderPage)
  }

  /** A slot can refresh host metadata for a page retained outside the native window. */
  private installSlotPage(page: ReaderPage): boolean {
    const previous = this.pages.get(page.sourceIndex)
    const value = page.copy()
    if (previous !== undefined) {
      // A routine slot snapshot cannot revoke a source fact already confirmed
      // by a resolver or by successful original presentation.
      value.bodySourceReady = value.bodySourceReady || previous.bodySourceReady
      value.bodySourceFailed = !value.bodySourceReady && (value.bodySourceFailed || previous.bodySourceFailed)
      // Thumbnail or retry metadata may omit native geometry. Keep the last
      // measured ORIGINAL dimensions until a new positive host value arrives.
      if (value.width <= 0 && previous.width > 0) value.width = previous.width
      if (value.height <= 0 && previous.height > 0) value.height = previous.height
    }
    if (value.bodySourceReady) value.bodySourceFailed = false
    if (previous !== undefined && this.samePageMetadata(previous, value)) return false
    this.pages.set(page.sourceIndex, value)
    return true
  }

  private samePageMetadata(left: ReaderPage, right: ReaderPage): boolean {
    const a = left.thumbnail
    const b = right.thumbnail
    return left.unit.equals(right.unit) && left.key === right.key && left.sourceIndex === right.sourceIndex &&
      left.width === right.width && left.height === right.height && left.bodySourceReady === right.bodySourceReady &&
      left.bodySourceFailed === right.bodySourceFailed && a.available === b.available && a.kind === b.kind &&
      a.width === b.width && a.height === b.height && a.spriteWidth === b.spriteWidth &&
      a.spriteHeight === b.spriteHeight && a.offsetX === b.offsetX && a.offsetY === b.offsetY
  }

  private publishPageMetadata(previous: ReaderPage | undefined, page: ReaderPage): void {
    const geometryChanged = previous === undefined || previous.key !== page.key ||
      previous.width !== page.width || previous.height !== page.height
    const displayed = (this.map?.item(this.state.displayIndex)?.parts ?? [])
      .some(part => part.sourceIndex === page.sourceIndex)
    // Metadata changes do not change page grouping unless wide-page splitting
    // changes. Keep the existing selected-position reconciliation (including its
    // selection receipt invalidation) without rebuilding every display item.
    if (this.map === null || !this.map.updatePage(page)) {
      this.rebuild()
    } else if (displayed && geometryChanged) {
      this.resolvePosition()
    } else {
      this.emit()
    }
  }

  reportPresentation(slotId: number, requestId: number, success: boolean, width: number = 0, height: number = 0): void {
    const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (this.disposed || slot === undefined) return
    const before = slot.session.snapshot()
    if (before.assetRequestId !== requestId || requestId === 0) return
    slot.session.reportPresentation(requestId, success)
    const rendered = slot.session.snapshot()
    // A successfully presented ORIGINAL proves a current body source. It
    // clears an earlier target-preheat failure and may refine native geometry;
    // thumbnail presentation never changes either source fact.
    if (!success || rendered.phase !== 'displayed' || before.kind !== 'original' || rendered.page === null ||
      this.state.phase !== 'ready') return
    const page = rendered.page.copy()
    page.bodySourceReady = true
    page.bodySourceFailed = false
    if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
      page.width = width
      page.height = height
    }
    if (this.state.policy.layout === 'continuous' || slot.unit?.key.equals(this.state.unit!.key) !== true) {
      this.installWindowPage(slot, page); this.emit(); return
    }
    const previous = this.pages.get(page.sourceIndex)?.copy()
    if (!this.installSlotPage(page)) return
    this.publishPageMetadata(previous, this.pages.get(page.sourceIndex) as ReaderPage)
  }

  private currentRenderSlot(selectionId: number, slotId: number, requestId: number,
    fragment: ReaderFragment): ReaderPageSlot | undefined {
    if (this.disposed || this.state.phase !== 'ready' || selectionId !== this.state.selectionId) return undefined
    const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (slot === undefined || requestId === 0 || slot.session.snapshot().assetRequestId !== requestId) return undefined
    return this.map?.item(this.state.displayIndex)?.parts.some((part: ReaderDisplayPart) =>
      part.unit.equals(slot.unit!.key) && part.sourceIndex === slot.index && part.fragment === fragment) ? slot : undefined
  }

  reportRenderFailure(selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void {
    this.currentRenderSlot(selectionId, slotId, requestId, fragment)?.session.reportRenderFailure(requestId)
  }

  /** Cached decode failure is asset evidence, never a reading-position observation. */
  reportCachedRenderFailure(topologyRevision: number, itemKey: string, slotId: number,
    requestId: number, fragment: ReaderFragment): void {
    if (this.disposed || topologyRevision !== this.topologyRevision || this.state.phase !== 'ready') return
    const nativeIndex = this.pagerRows.findIndex((row: ReaderPagerRow): boolean => row.key === itemKey)
    const frames = this.state.policy.layout !== 'continuous' && nativeIndex >= 0
      ? this.framesForPagerRow(nativeIndex) : this.framesAt(this.localIndexForItemKey(itemKey))
    const frame = frames.find((candidate: ReaderPagedFrame) =>
      candidate.slotId === slotId && candidate.asset.assetRequestId === requestId && candidate.part.fragment === fragment)
    if (frame !== undefined) this.slots.find((slot: ReaderPageSlot) => slot.id === slotId)?.session.reportRenderFailure(requestId)
  }

  reportVisible(selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): boolean {
    if (!this.active || this.state.phase !== 'ready' || selectionId !== this.state.selectionId ||
      this.state.policy.layout === 'continuous' ||
      this.state.kind !== 'original' || this.state.anchor === null || this.map === null) return false
    const slot = this.currentRenderSlot(selectionId, slotId, requestId, fragment)
    if (slot === undefined) return false
    if (this.cropEnabled && !this.cropPresentationDeferred && (slot.cropRequestId !== requestId || !slot.cropSettled)) return false
    const asset = slot.session.snapshot()
    const anchor = this.state.anchor
    // A spread's second page decoding first must not change the selected original.
    if (asset.phase !== 'displayed' || asset.assetRequestId !== requestId || asset.page?.key !== anchor.pageKey) return false
    if (this.state.observedSelectionId === selectionId) return true
    this.state.observedAnchor = anchor.copy()
    this.state.observedSelectionId = selectionId
    if (this.outgoingPositionKey !== null) {
      this.outgoingPositionKey = null
      this.reconcile()
    } else this.emit()
    return true
  }

  /** The List reports global rows; selection/progress remain real unit-local anchors. */
  setContinuousRange(start: number, end: number, topologyRevision: number, navigationRevision: number,
    positionIndex: number = start): boolean {
    if (!this.active || this.state.phase !== 'ready' || this.state.policy.layout !== 'continuous' ||
      topologyRevision !== this.topologyRevision || navigationRevision !== this.navigationRevision ||
      !Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start ||
      end >= this.continuousRows.length || !Number.isInteger(positionIndex) || positionIndex < start || positionIndex > end) return false
    if (start === this.continuousStart && end === this.continuousEnd &&
      positionIndex === this.continuousSelectedIndex()) return true
    this.continuousStart = start; this.continuousEnd = end
    this.selectContinuousRow(positionIndex)
    this.reconcile()
    return true
  }

  reportContinuousVisible(topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, x: number, y: number): boolean {
    const index = this.continuousSelectedIndex()
    if (!this.active || this.state.phase !== 'ready' || this.state.policy.layout !== 'continuous' ||
      this.state.kind !== 'original' || topologyRevision !== this.topologyRevision ||
      navigationRevision !== this.navigationRevision || this.continuousStart < 0 ||
      index < this.continuousStart || index > this.continuousEnd || itemKey !== this.displayKeys[index] ||
      !Number.isFinite(x) || !Number.isFinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return false
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame): boolean =>
      candidate.slotId === slotId && candidate.asset.assetRequestId === requestId &&
      candidate.asset.phase === 'displayed' && candidate.asset.kind === 'original')
    if (frame === undefined || requestId === 0 || frame.part.pageKey === null) return false
    const anchor = new ReaderReadingAnchor(frame.part.unit, frame.part.pageKey, frame.part.sourceIndex, x, y)
    const previous = this.state.observedAnchor
    const positionOnly = previous !== null && previous.unit.equals(anchor.unit) &&
      previous.pageKey === anchor.pageKey && this.state.observedSelectionId === this.state.selectionId
    this.state.anchor = anchor.copy()
    this.state.observedAnchor = anchor
    this.state.observedSelectionId = this.state.selectionId
    if (positionOnly && this.positionListener !== null) this.positionListener(anchor.copy(), this.state.selectionId)
    else this.emit()
    return true
  }

  private pagerSelectedIndex(): number {
    return Math.max(0, this.pagerRows.findIndex((row: ReaderPagerRow): boolean =>
      this.state.unit?.key.equals(row.context.unit.key) === true && row.index === this.state.displayIndex))
  }

  private rebuildPagerRows(): void {
    const oldResources = this.resourceWindowIndexes.map((index: number): string => this.pagerRows[index]?.key ?? '')
    const rows: ReaderPagerRow[] = []
    this.windowUnits.forEach((context: ReaderWindowUnit): void => {
      context.map = context.unit.key.equals(this.state.unit!.key) ? this.map : context.map ??
        new ReaderDisplayMap(context.unit, Array.from(context.pages.values()), this.state.policy)
      for (let index = 0; index < (context.map?.count() ?? 0); index++) rows.push(new ReaderPagerRow(context, index))
    })
    const previousUnits: Set<ReaderWindowUnit> = new Set(this.pagerRows.map((row: ReaderPagerRow): ReaderWindowUnit => row.context))
    const nextUnits: Set<ReaderWindowUnit> = new Set(rows.map((row: ReaderPagerRow): ReaderWindowUnit => row.context))
    const sameUnits = previousUnits.size > 0 && previousUnits.size === nextUnits.size &&
      Array.from(previousUnits).every((context: ReaderWindowUnit): boolean => nextUnits.has(context))
    if (sameUnits && (this.pagerRows.length !== rows.length || this.pagerRows.some(
      (row: ReaderPagerRow, index: number): boolean => row.key !== rows[index].key))) this.topologyRevision += 1
    this.pagerRows = rows
    this.resourceWindowIndexes = oldResources.map((key: string): number => rows.findIndex(
      (row: ReaderPagerRow): boolean => row.key === key)).filter((index: number): boolean => index >= 0)
  }

  private framesForPagerRow(index: number): ReaderPagedFrame[] {
    const row = this.pagerRows[index]
    if (row === undefined) return []
    return (row.context.map?.item(row.index)?.visualParts(this.state.policy.direction) ?? [])
      .map((part: ReaderDisplayPart): ReaderPagedFrame | null => {
        const slot = this.slots.find((candidate: ReaderPageSlot): boolean =>
          candidate.unit?.key.equals(part.unit) === true && candidate.index === part.sourceIndex)
        if (slot === undefined) return null
        const asset = slot.session.snapshot()
        const page = row.context.pages.get(part.sourceIndex)
        if (page !== undefined && asset.page !== null) asset.page = page.copy()
        const crop = this.cropEnabled && !this.cropPresentationDeferred && slot.cropRequestId === asset.assetRequestId
          ? slot.crop?.copy() ?? new ReaderImageCropBounds() : new ReaderImageCropBounds()
        const frame = new ReaderPagedFrame(slot.id, part, asset, crop)
        frame.cropPending = this.cropEnabled && !this.cropPresentationDeferred && asset.kind === 'original' &&
          (slot.cropRequestId !== asset.assetRequestId || !slot.cropSettled)
        return frame
      }).filter((frame: ReaderPagedFrame | null): boolean => frame !== null) as ReaderPagedFrame[]
  }

  /** A native swipe/tap promotes an already prepared real chapter, retaining its Image slots. */
  selectPagerIndex(index: number, topology: number, navigation: number): boolean {
    if (!this.active || this.disposed || this.state.phase !== 'ready' || this.state.policy.layout === 'continuous' ||
      topology !== this.topologyRevision || navigation !== this.navigationRevision || !Number.isInteger(index)) return false
    const row = this.pagerRows[index]
    if (row === undefined) return false
    if (row.context.unit.key.equals(this.state.unit!.key)) return this.selectDisplay(row.index, topology, navigation)
    this.beginPositionHandoff()
    this.cancelOriginalPreparations(); this.cancelAutoReadSourcePreparations()
    this.navigationRevision += 1
    this.state.unit = row.context.unit.copy()
    this.pages = row.context.pages; this.cropPages = row.context.crops; this.assetPlans = row.context.plans
    this.processing = row.context.processing; this.map = row.context.map
    this.state.displayIndex = row.index
    this.state.anchor = this.map?.anchorAt(row.index) ?? null
    this.state.selectionId += 1
    this.state.canPreviousUnit = this.catalog.adjacent(row.context.unit.copy(), 'previous') !== null
    this.state.canNextUnit = this.catalog.adjacent(row.context.unit.copy(), 'next') !== null
    this.displayKeys = []
    for (let local = 0; local < (this.map?.count() ?? 0); local++) {
      this.displayKeys.push((this.map?.item(local)?.parts ?? []).map((part: ReaderDisplayPart): string =>
        `${part.sourceIndex}:${part.fragment}`).join('+'))
    }
    this.reconcile()
    return true
  }

  private syncPagerProcessing(): void {
    const policy = this.state.kind === 'original' && this.state.phase === 'ready' ? this.processingPolicy : null
    const selected = this.pagerSelectedIndex()
    const demanded = this.resourceWindowIndexes.slice()
    // Automatic translation owns one future recipe even when image preloading
    // is zero. This does not add a native Image lease or invent another chapter.
    const lookahead = Math.max(this.preloadDepth, policy?.automaticNext === true ? 1 : 0)
    for (let index = selected + 1; index < this.pagerRows.length && index <= selected + lookahead; index++) {
      if (!demanded.includes(index)) demanded.push(index)
    }
    const contexts: ReaderWindowUnit[] = []
    demanded.forEach((index: number): void => {
      const context = this.pagerRows[index]?.context
      if (context !== undefined && !contexts.includes(context)) contexts.push(context)
    })
    this.continuousProcessingUnits.forEach((context: ReaderWindowUnit): void => {
      if (!contexts.includes(context) || policy === null) context.processing.clear()
    })
    this.continuousProcessingUnits = contexts
    if (policy === null) return
    contexts.forEach((context: ReaderWindowUnit): void => {
      const indexes: number[] = []
      demanded.forEach((index: number): void => {
        const row = this.pagerRows[index]
        if (row?.context !== context) return
        row.context.map?.item(row.index)?.parts.forEach((part: ReaderDisplayPart): void => {
          if (!indexes.includes(part.sourceIndex)) indexes.push(part.sourceIndex)
        })
      })
      const current = context.unit.key.equals(this.state.unit!.key)
        ? (this.map?.item(this.state.displayIndex)?.parts ?? []).map((part: ReaderDisplayPart): number => part.sourceIndex) : []
      const nextRow = this.pagerRows[selected + 1]
      const automatic = nextRow?.context === context ? nextRow.context.map?.item(nextRow.index)?.parts[0]?.sourceIndex ?? -1 : -1
      const contextPolicy = context.processing === this.processing ? policy :
        new ReaderProcessingPolicy(policy.revision, policy.automaticNext,
          (page: ReaderPage, automatic: boolean): ReaderVariantPreference => policy.preference(page, automatic))
      context.processing.update(context.unit, indexes.filter((index: number): boolean =>
        (!context.unit.key.equals(this.state.unit!.key) || !this.processingReloads.has(index)) &&
        context.plans.get(index)?.variant !== 'original'), current, automatic, contextPolicy,
        this.active && this.processingAllowed, this.cropEnabled, this.processingCropRevision)
    })
  }

  private continuousSelectedIndex(): number {
    if (this.state.policy.layout !== 'continuous') return this.state.displayIndex
    return Math.max(0, this.continuousRows.findIndex((row: ReaderContinuousRow): boolean =>
      this.state.unit?.key.equals(row.context.unit.key) === true && row.index === this.state.displayIndex))
  }

  private ensureWindowCurrent(): ReaderWindowUnit | null {
    const unit = this.state.unit
    if (unit === null) return null
    let context = this.windowUnits.find((value: ReaderWindowUnit): boolean => value.unit.key.equals(unit.key))
    if (context === undefined) {
      context = new ReaderWindowUnit(unit, this.processing)
      context.pages = this.pages; context.crops = this.cropPages; context.plans = this.assetPlans
      this.windowUnits.push(context)
    }
    context.map = this.map
    return context
  }

  /** Keep discovered row identities/geometry stable for this reading session.
   * 197 showed a reverse jump when deleting preceding unmeasured rows changed
   * ArkUI's offset estimate. Metadata is not an image lease: slots and prepared
   * files still retire through their independent bounded demand windows.
   */
  private rebuildContinuousRows(): void {
    const previousResources = this.resourceWindowIndexes.map((index: number): string => this.displayKeys[index])
    const previousStart = this.displayKeys[this.continuousStart]
    const previousEnd = this.displayKeys[this.continuousEnd]
    const rows: ReaderContinuousRow[] = []
    this.windowUnits.forEach((context: ReaderWindowUnit): void => {
      for (let index = 0; index < context.unit.pageCount; index++) rows.push(new ReaderContinuousRow(context, index))
    })
    this.continuousRows = rows
    this.displayKeys = rows.map((row: ReaderContinuousRow): string => row.key)
    this.resourceWindowIndexes = previousResources.map((key: string): number => this.displayKeys.indexOf(key))
      .filter((index: number): boolean => index >= 0)
    if (previousStart !== undefined) this.continuousStart = this.displayKeys.indexOf(previousStart)
    if (previousEnd !== undefined) this.continuousEnd = this.displayKeys.indexOf(previousEnd)
  }

  private appendWindowUnit(unit: ReaderUnit, before: boolean = false): void {
    if (unit.pageCount < 1 ||
      this.windowUnits.some((context: ReaderWindowUnit): boolean => context.unit.key.equals(unit.key))) return
    const context = new ReaderWindowUnit(unit, this.futureProcessing.get(this.processingUnitId(unit.key)) ??
      this.createProcessingCoordinator())
    this.futureProcessing.delete(this.processingUnitId(unit.key))
    if (before) this.windowUnits.unshift(context)
    else this.windowUnits.push(context)
    if (this.state.policy.layout === 'continuous') this.rebuildContinuousRows()
    else this.rebuildPagerRows()
    this.reconcile()
  }

  private selectContinuousRow(index: number): void {
    const row = this.continuousRows[index]
    if (row === undefined) return
    const changed = this.state.unit?.key.equals(row.context.unit.key) !== true || this.state.displayIndex !== row.index
    if (!changed) return
    this.cancelOriginalPreparations(); this.cancelAutoReadSourcePreparations()
    this.state.unit = row.context.unit.copy()
    this.pages = row.context.pages; this.cropPages = row.context.crops; this.assetPlans = row.context.plans
    this.processing = row.context.processing
    this.map = new ReaderDisplayMap(row.context.unit, Array.from(this.pages.values()), this.state.policy)
    this.state.displayIndex = row.index
    this.state.anchor = new ReaderReadingAnchor(row.context.unit.key, this.pages.get(row.index)?.key ?? null, row.index)
    this.state.selectionId += 1
    this.state.canPreviousUnit = this.catalog.adjacent(row.context.unit.copy(), 'previous') !== null
    this.state.canNextUnit = this.catalog.adjacent(row.context.unit.copy(), 'next') !== null
    // Native motion never increments navigation/topology or commands a new List position.
  }

  private continuousRowCrop(row: ReaderContinuousRow): ReaderImageCropBounds {
    return this.cropEnabled && !this.cropPresentationDeferred && this.state.kind === 'original'
      ? (row.context.crops.get(row.index) ?? new ReaderImageCropBounds())
        .forContinuousPage(row.index, row.context.unit.pageCount) : new ReaderImageCropBounds()
  }

  private installWindowPage(slot: ReaderPageSlot, page: ReaderPage): void {
    const context = this.windowUnits.find((value: ReaderWindowUnit): boolean => value.unit.key.equals(page.unit))
    if (context === undefined || slot.unit?.key.equals(page.unit) !== true || page.sourceIndex !== slot.index) return
    const previous = context.pages.get(page.sourceIndex)
    const value = page.copy()
    if (previous !== undefined) {
      if (value.width <= 0) value.width = previous.width
      if (value.height <= 0) value.height = previous.height
      value.bodySourceReady = value.bodySourceReady || previous.bodySourceReady
    }
    context.pages.set(page.sourceIndex, value)
    if (this.state.policy.layout !== 'continuous') {
      if (context.map?.updatePage(value) !== true) { context.map = null; this.rebuildPagerRows() }
    }
    if (this.state.unit?.key.equals(page.unit) === true) {
      this.map?.updatePage(value)
      if (this.state.anchor?.sourceIndexHint === page.sourceIndex && this.state.anchor.pageKey === null) {
        this.state.anchor = new ReaderReadingAnchor(page.unit, value.key, page.sourceIndex,
          this.state.anchor.x, this.state.anchor.y)
      }
    }
  }

  private syncContinuousProcessing(): void {
    const policy = this.processingPolicy
    if (policy === null) return
    const selected = this.continuousSelectedIndex()
    const end = this.continuousEnd >= 0 ? this.continuousEnd : selected
    const demanded = this.resourceWindowIndexes.slice()
    const lookahead = Math.max(this.preloadDepth, policy.automaticNext ? 1 : 0)
    for (let index = end + 1; index < this.continuousRows.length && index <= end + lookahead; index++) {
      if (!demanded.includes(index)) demanded.push(index)
    }
    const contexts: ReaderWindowUnit[] = []
    demanded.forEach((index: number): void => {
      const context = this.continuousRows[index]?.context
      if (context !== undefined && !contexts.includes(context)) contexts.push(context)
    })
    this.continuousProcessingUnits.forEach((context: ReaderWindowUnit): void => {
      if (!contexts.includes(context)) context.processing.clear()
    })
    this.continuousProcessingUnits = contexts
    contexts.forEach((context: ReaderWindowUnit): void => {
      const indexes = demanded.filter((index: number): boolean => this.continuousRows[index]?.context === context)
        .map((index: number): number => this.continuousRows[index].index)
      const current = this.continuousRows[selected]?.context === context ? [this.continuousRows[selected].index] : []
      const automatic = this.continuousRows[selected + 1]?.context === context ? this.continuousRows[selected + 1].index : -1
      const contextPolicy = context.processing === this.processing ? policy :
        new ReaderProcessingPolicy(policy.revision, policy.automaticNext,
          (page: ReaderPage, automatic: boolean): ReaderVariantPreference => policy.preference(page, automatic))
      context.processing.update(context.unit, indexes, current, automatic, contextPolicy,
        this.active && this.processingAllowed, this.cropEnabled, this.processingCropRevision)
    })
  }

  requestContinuousBoundary(topology: number, navigation: number): void {
    if (!this.active || this.state.policy.layout !== 'continuous' ||
      topology !== this.topologyRevision || navigation !== this.navigationRevision) return
    this.prepareWindowAdjacent()
  }

  private prepareWindowAdjacent(): void {
    if (!this.active || this.disposed || this.windowUnits.length === 0) return
    const selected = this.state.policy.layout === 'continuous' ? this.continuousSelectedIndex() : this.pagerSelectedIndex()
    const prepare = (context: ReaderWindowUnit, direction: 'previous' | 'next'): void => {
      const key = this.catalog.adjacent(context.unit.copy(), direction)
      if (key === null || this.windowUnits.some((value: ReaderWindowUnit): boolean => value.unit.key.equals(key))) return
      const id = this.processingUnitId(key)
      if (this.continuousCatalogTasks.has(id)) return
      this.continuousCatalogTasks.add(id)
      const cancellation = this.continuousCatalogCancellation
      void this.catalog.open(key.copy(), cancellation).then((unit: ReaderUnit): void => {
        if (cancellation.isCancelled() || this.disposed || !unit.key.equals(key)) return
        this.appendWindowUnit(unit, direction === 'previous')
      }).catch((): void => {}).finally((): void => {
        if (this.continuousCatalogCancellation === cancellation) this.continuousCatalogTasks.delete(id)
      })
    }
    // One adjacent chapter remains available even when transport lookahead is off.
    const previousLead = Math.max(2, this.continuousEnd - this.continuousStart + 1)
    if (selected <= previousLead) prepare(this.windowUnits[0], 'previous')
    const count = this.state.policy.layout === 'continuous' ? this.continuousRows.length : this.pagerRows.length
    if (this.state.policy.layout === 'continuous' && count - selected <= Math.max(2, this.preloadDepth + 1)) {
      prepare(this.windowUnits[this.windowUnits.length - 1], 'next')
    }
  }

  private reconcileContinuousSlots(): void {
    this.ensureWindowCurrent()
    const selected = this.continuousSelectedIndex()
    const start = this.continuousStart >= 0 ? this.continuousStart : selected
    const end = this.continuousEnd >= start ? this.continuousEnd : selected
    const depth = this.prefetchNeighbors ? this.nativeNeighborDepth() : 0
    const requested: number[] = []
    for (let index = start; index <= end; index++) requested.push(index)
    for (let offset = 1; offset <= depth; offset++) {
      if (start - offset >= 0) requested.push(start - offset)
      if (end + offset < this.continuousRows.length) requested.push(end + offset)
    }
    const spare = this.prefetchNeighbors && this.pagedPreloadDepth !== null && this.pagedPreloadDepth > 0
      ? this.resourceWindowIndexes.filter((index: number): boolean => !requested.includes(index) &&
        index >= Math.max(0, start - depth - 1) && index <= end + depth + 1).slice(0, 1) : []
    this.resourceWindowIndexes = requested.concat(spare)
    this.syncContinuousProcessing()
    const rows = this.resourceWindowIndexes.map((index: number): ReaderContinuousRow => this.continuousRows[index])
      .filter((row: ReaderContinuousRow): boolean => row !== undefined)
    const removed = this.slots.filter((slot: ReaderPageSlot): boolean => !rows.some((row: ReaderContinuousRow): boolean =>
      slot.unit?.key.equals(row.context.unit.key) === true && slot.index === row.index && slot.kind === this.state.kind))
    this.slots = this.slots.filter((slot: ReaderPageSlot): boolean => !removed.includes(slot))
    removed.forEach((slot: ReaderPageSlot): void => slot.session.close())
    rows.forEach((row: ReaderContinuousRow): void => {
      const explicit = row.context.plans.get(row.index) ?? null
      const plan = explicit?.variant === 'original' || this.processingPolicy === null ? explicit : row.context.processing.plan(row.index)
      const existing = this.slots.find((slot: ReaderPageSlot): boolean => slot.unit?.key.equals(row.context.unit.key) === true &&
        slot.index === row.index)
      if (existing !== undefined) {
        if (existing.assetPlan !== plan) { existing.assetPlan = plan; void existing.session.show(row.index, this.state.kind, false, plan) }
        return
      }
      const slot = new ReaderPageSlot(++this.slotSerial, row.index, this.state.kind,
        new ReaderSession(this.catalog, this.assets, this.failures), plan)
      slot.unit = row.context.unit.copy()
      this.slots.push(slot)
      slot.session.subscribe((snapshot: ReaderSnapshot): void => this.slotChanged(slot, snapshot))
      void slot.session.openPrepared(row.context.unit, row.index, slot.kind, plan)
    })
    this.schedulePreload()
    this.prepareWindowAdjacent()
  }

  private clearWindowUnits(keep: ReaderProcessingCoordinator | null = null): void {
    this.continuousCatalogCancellation.cancel()
    this.continuousCatalogCancellation = new ReaderCancellation()
    this.continuousCatalogTasks.clear()
    this.windowUnits.forEach((context: ReaderWindowUnit): void => {
      if (context.processing !== this.processing && context.processing !== keep) context.processing.clear()
    })
    this.windowUnits = []; this.continuousRows = []; this.pagerRows = []; this.continuousProcessingUnits = []
    this.resourceWindowIndexes = []
  }

  private releaseSlots(): void {
    const slots = this.slots
    this.slots = []
    this.resourceWindowIndexes = []
    slots.forEach((slot: ReaderPageSlot): void => slot.session.close())
  }

  close(): void {
    this.outgoingPositionKey = null
    this.processing.clear()
    this.retireFutureProcessing()
    this.cancelOriginalPreparations()
    this.cancelAutoReadSourcePreparations()
    this.assetPlans.clear()
    if (this.disposed) return
    this.nextUnitPreloadSignature = ''
    this.nextUnitPreloadCancellation.cancel()
    this.disposed = true
    this.active = false
    this.cancellation.cancel()
    this.preloadCancellation.cancel()
    this.preloadEpoch += 1
    this.preloadSignature = ''
    this.epoch += 1
    this.releaseSlots()
    this.clearWindowUnits()
    this.state.phase = 'closed'
    this.emit()
    this.listener = null
    this.positionListener = null
  }
}
