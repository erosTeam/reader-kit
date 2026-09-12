import { ReaderUnitKey, ReaderUnit, ReaderPage } from './ReaderContent'
import {
  ReaderSession, ReaderSnapshot, ReaderCatalog, ReaderAssetProvider, ReaderAssetKind, ReaderAssetVariant,
  ReaderCancellation, ReaderProcessedAssetVariant, ReaderResolvedAssetPlan, ReaderVariantAssetPlan,
} from './ReaderSession'
import { ReaderDisplayMap, ReaderDisplayPolicy, ReaderDisplayPart, ReaderReadingAnchor, ReaderFragment } from './ReaderDisplayMap'
import { ReaderThumbnailWindow } from './ReaderThumbnailWindow'
import { ReaderImageInformation } from './ReaderImageInformation'
import { ReaderImageCropBounds } from './ReaderImageCrop'

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

export class ReaderPagedSnapshot {
  unit: ReaderUnit | null = null
  phase: 'idle' | 'catalog' | 'ready' | 'failed' | 'closed' = 'idle'
  error: string = ''
  policy: ReaderDisplayPolicy = new ReaderDisplayPolicy()
  kind: ReaderAssetKind = 'original'
  originalPreparing: boolean = false
  variantPreparing: boolean = false
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
  window: ReaderPagedItemSnapshot[] = []
  /** Geometry metadata may outlive an evicted asset; it is never an image lease. */
  pageMetadata: ReaderPage[] = []
  cropMetadata: ReaderPageCropMetadata[] = []
  cropForPage(index: number): ReaderImageCropBounds {
    return this.cropMetadata.find((value: ReaderPageCropMetadata) => value.sourceIndex === index)?.bounds.copy()
      ?? new ReaderImageCropBounds()
  }
  canPreviousUnit: boolean = false
  canNextUnit: boolean = false

  /** A cached item's render projection, not a second selection or observed anchor. */
  forItem(key: string): ReaderPagedSnapshot {
    const value = new ReaderPagedSnapshot()
    value.unit = this.unit?.copy() ?? null
    value.phase = this.phase
    value.policy = this.policy.copy()
    value.kind = this.kind
    value.originalPreparing = this.originalPreparing
    value.variantPreparing = this.variantPreparing
    value.cropEnabled = this.cropEnabled
    value.displayIndex = this.displayKeys.indexOf(key)
    value.displayCount = this.displayCount
    value.selectionId = this.selectionId
    value.anchor = this.anchor?.copy() ?? null
    value.topologyRevision = this.topologyRevision
    value.navigationRevision = this.navigationRevision
    value.frames = (this.window.find((item: ReaderPagedItemSnapshot) => item.key === key)?.frames ?? [])
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
  crop: ReaderImageCropBounds | null = null
  cropSettled: boolean = false
  id: number
  index: number
  kind: ReaderAssetKind
  session: ReaderSession
  assetPlan: ReaderResolvedAssetPlan | null

  constructor(id: number, index: number, kind: ReaderAssetKind, session: ReaderSession,
    assetPlan: ReaderResolvedAssetPlan | null = null) {
    this.id = id
    this.index = index
    this.kind = kind
    this.session = session
    this.assetPlan = assetPlan
  }
}

/**
 * One display/anchor owner. Selected-only uses at most two asset slots; the
 * paged neighbor window uses at most six. Continuous demand uses the visible
 * range plus its immediate neighbors. ReaderSession continues to
 * own each request, decoder fence and lease; hosts still own chapter semantics.
 * Metadata is discovered only within the requested window, never by opening every page.
 */
export class ReaderPagedSession {
  private readonly catalog: ReaderCatalog
  private readonly assets: ReaderAssetProvider
  private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  private map: ReaderDisplayMap | null = null
  private pages: Map<number, ReaderPage> = new Map()
  private cropPages: Map<number, ReaderImageCropBounds> = new Map()
  private slots: ReaderPageSlot[] = []
  private assetPlans: Map<number, ReaderResolvedAssetPlan> = new Map()
  private originalPreparations: Map<number, ReaderCancellation> = new Map()
  private preparationVariants: Map<number, ReaderAssetVariant> = new Map()
  private prefetchNeighbors: boolean = false
  private displayKeys: string[] = []
  private topologySignature: string = ''
  private topologyRevision: number = 0
  private navigationRevision: number = 0
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
  private activityEpoch: number = 0
  private listener: ((snapshot: ReaderPagedSnapshot) => void) | null = null

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider) {
    this.catalog = catalog
    this.assets = assets
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

  private requestCrop(slot: ReaderPageSlot, snapshot: ReaderSnapshot): void {
    if (!this.cropEnabled || snapshot.kind !== 'original' || snapshot.assetRequestId === 0 ||
      (snapshot.phase !== 'decoding' && snapshot.phase !== 'displayed') ||
      slot.cropRequestId === snapshot.assetRequestId) return
    const requestId = snapshot.assetRequestId
    slot.cropRequestId = requestId
    slot.crop = null
    slot.cropSettled = false
    void slot.session.imageCrop(requestId).then((crop: ReaderImageCropBounds | null): void => {
      if (this.disposed || !this.slots.includes(slot) || slot.cropRequestId !== requestId ||
        slot.session.snapshot().assetRequestId !== requestId) return
      slot.crop = crop?.copy() ?? null
      slot.cropSettled = true
      this.cropPages.set(slot.index, crop?.copy() ?? new ReaderImageCropBounds())
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
      this.navigationRevision === navigation && this.framesAt(this.state.displayIndex)
        .some((frame: ReaderPagedFrame): boolean => frame.slotId === slotId && frame.asset.assetRequestId === requestId)
    if (!selected()) return null
    const slot = this.slots.find((value: ReaderPageSlot): boolean => value.id === slotId)
    const information = await slot?.session.imageInformation(requestId) ?? null
    return selected() ? information : null
  }
  /** The caller owns and closes the auxiliary preview leases, never reading progress. */
  createThumbnailWindow(): ReaderThumbnailWindow { return new ReaderThumbnailWindow(this.catalog, this.assets) }
  setViewportActive(active: boolean): void {
    if (!active) this.cancelOriginalPreparations()
    if (this.active && !active) this.activityEpoch += 1
    this.active = active && !this.disposed
  }
  subscribe(listener: (snapshot: ReaderPagedSnapshot) => void): void {
    this.listener = listener
    this.emit()
  }

  snapshot(): ReaderPagedSnapshot {
    const value = new ReaderPagedSnapshot()
    value.unit = this.state.unit?.copy() ?? null
    value.phase = this.state.phase
    value.canShiftSpread = this.spreadShiftTarget() !== null
    value.error = this.state.error
    value.policy = this.state.policy.copy()
    value.kind = this.state.kind
    value.originalPreparing = Array.from(this.preparationVariants.values())
      .some((variant: ReaderAssetVariant): boolean => variant === 'original')
    value.variantPreparing = this.originalPreparations.size > 0
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
    value.displayKeys = this.displayKeys.slice()
    value.pageMetadata = Array.from(this.pages.values()).map((page: ReaderPage) => page.copy())
    if (this.cropEnabled && this.state.kind === 'original') {
      this.cropPages.forEach((bounds: ReaderImageCropBounds, index: number) => {
        value.cropMetadata.push(new ReaderPageCropMetadata(index, this.state.policy.layout === 'continuous'
          ? bounds.forContinuousPage(index, this.state.unit?.pageCount ?? 0) : bounds))
      })
    }
    value.frames = this.framesAt(this.state.displayIndex)
    value.window = this.windowIndexes().map((index: number) =>
      new ReaderPagedItemSnapshot(this.displayKeys[index], index, this.framesAt(index)))
    return value
  }

  private framesAt(index: number): ReaderPagedFrame[] {
    const parts = this.map?.item(index)?.visualParts(this.state.policy.direction) ?? []
    return parts.filter((part: ReaderDisplayPart) =>
      this.slots.some((slot: ReaderPageSlot) => slot.index === part.sourceIndex))
      .map((part: ReaderDisplayPart): ReaderPagedFrame => {
      const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.index === part.sourceIndex)
      const asset = slot?.session.snapshot() ?? new ReaderSnapshot()
      const page = this.pages.get(part.sourceIndex)
      if (page !== undefined && asset.page !== null) asset.page = page.copy()
      let crop = this.cropEnabled && slot?.cropRequestId === asset.assetRequestId
        ? slot?.crop?.copy() ?? new ReaderImageCropBounds() : new ReaderImageCropBounds()
      if (this.state.policy.layout === 'continuous') {
        crop = crop.forContinuousPage(part.sourceIndex, this.state.unit?.pageCount ?? 0)
      }
      const frame = new ReaderPagedFrame(slot?.id ?? 0, part, asset, crop)
      frame.cropPending = this.cropEnabled && asset.kind === 'original' &&
        (slot?.cropRequestId !== asset.assetRequestId || slot?.cropSettled !== true)
      return frame
    })
  }

  private windowIndexes(): number[] {
    if (this.map === null || this.map.count() === 0) return []
    if (this.state.policy.layout === 'continuous' && this.continuousStart >= 0) {
      const indexes: number[] = []
      for (let index = this.continuousStart; index <= this.continuousEnd; index++) indexes.push(index)
      if (this.prefetchNeighbors && this.continuousStart > 0) indexes.push(this.continuousStart - 1)
      if (this.prefetchNeighbors && this.continuousEnd + 1 < this.map.count()) indexes.push(this.continuousEnd + 1)
      return indexes
    }
    const indexes: number[] = [this.state.displayIndex]
    if (this.prefetchNeighbors) {
      if (this.state.displayIndex > 0) indexes.push(this.state.displayIndex - 1)
      if (this.state.displayIndex + 1 < this.map.count()) indexes.push(this.state.displayIndex + 1)
    }
    return indexes
  }

  setNeighborPreload(enabled: boolean): void {
    if (this.disposed || enabled === this.prefetchNeighbors) return
    this.prefetchNeighbors = enabled
    if (this.state.phase === 'ready') this.reconcile()
  }

  private emit(): void { if (this.listener !== null) this.listener(this.snapshot()) }

  async open(key: ReaderUnitKey, index: number = 0): Promise<void> {
    if (this.disposed) return
    this.cancelOriginalPreparations()
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
    this.state.policy = policy.copy()
    this.cancelOriginalPreparations()
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
    if (!this.active || !this.state.unit?.key.equals(unit) || topology !== this.topologyRevision ||
      navigation !== this.navigationRevision) return false
    const target = this.spreadShiftTarget()
    if (target === null) return false
    this.cancelOriginalPreparations()
    this.state.policy = this.state.policy.copy()
    this.state.policy.firstPageAlone = target % 2 === 1
    this.navigationRevision += 1
    this.state.anchor = new ReaderReadingAnchor(unit, this.pages.get(target)?.key ?? null, target)
    this.rebuild()
    return true
  }

  /** A source-page command, not a display index or an observed/saved reading position.
   * A slider may outlive its unit/navigation; stale commits must not seek the new unit.
   */
  seekSource(index: number, unit: ReaderUnitKey, navigationRevision: number): boolean {
    if (this.disposed || this.state.phase !== 'ready' || this.state.unit === null ||
      !this.state.unit.key.equals(unit) || navigationRevision !== this.navigationRevision ||
      !Number.isSafeInteger(index) || index < 0 || index >= this.state.unit.pageCount) return false
    this.cancelOriginalPreparations()
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
    this.cancelOriginalPreparations()
    this.navigationRevision += 1
    this.continuousStart = -1
    this.continuousEnd = -1
    this.state.anchor = this.map.anchorAt(index)
    this.rebuild()
    return true
  }

  setAssetKind(kind: ReaderAssetKind): void {
    if (this.disposed || this.state.phase !== 'ready' || kind === this.state.kind) return
    if (kind === 'thumbnail' && this.snapshot().frames.some((frame: ReaderPagedFrame) =>
      frame.asset.page === null || !frame.asset.page.thumbnail.available)) return
    this.state.kind = kind
    this.cancelOriginalPreparations()
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

  async retry(): Promise<void> {
    if (this.disposed) return
    if (this.pendingUnit !== null) await this.open(this.pendingUnit, this.pendingIndex)
    else await Promise.all(this.slots.filter((slot: ReaderPageSlot) => slot.session.snapshot().phase === 'failed' &&
      this.map?.item(this.state.displayIndex)?.parts.some((part: ReaderDisplayPart) => part.sourceIndex === slot.index))
      .map((slot: ReaderPageSlot) => slot.session.retry()))
  }

  /** Retry one visible failed asset without selecting it or reopening its host unit. */
  async retryItem(topologyRevision: number, itemKey: string, slotId: number, requestId: number): Promise<boolean> {
    if (this.disposed || !this.active || this.state.phase !== 'ready' || topologyRevision !== this.topologyRevision) return false
    const index = this.displayKeys.indexOf(itemKey)
    const visible = this.state.policy.layout === 'continuous'
      ? this.continuousStart >= 0 && index >= this.continuousStart && index <= this.continuousEnd
      : index === this.state.displayIndex
    if (!visible) return false
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame) => candidate.slotId === slotId &&
      candidate.asset.requestId === requestId && candidate.asset.phase === 'failed')
    const slot = frame === undefined ? undefined : this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (slot === undefined) return false
    await slot.session.retry()
    return true
  }

  private rebuild(): void {
    if (this.state.unit === null || this.state.anchor === null) return
    this.map = new ReaderDisplayMap(this.state.unit, Array.from(this.pages.values()), this.state.policy)
    const keys: string[] = []
    for (let index = 0; index < this.map.count(); index++) {
      keys.push((this.map.item(index)?.parts ?? []).map((part: ReaderDisplayPart) =>
        `${part.sourceIndex}:${part.fragment}`).join('+'))
    }
    const pagingAxis = this.state.policy.layout === 'continuous' ? 'horizontal' : this.state.policy.pagingAxis
    const signature = `${this.state.policy.layout}:${this.state.policy.direction}:${pagingAxis}:` + keys.join('|')
    if (signature !== this.topologySignature) {
      this.topologySignature = signature
      this.topologyRevision += 1
      this.displayKeys = keys
    }
    const resolved = this.map.resolve(this.state.anchor)
    if (!resolved.resolved()) {
      this.state.error = 'reader_anchor_unresolved'
      this.state.phase = 'failed'
      this.emit()
      return
    }
    this.state.anchor = resolved.anchor
    this.state.displayIndex = resolved.displayIndex
    this.state.selectionId += 1
    this.reconcile()
  }

  private reconcile(): void {
    const unit = this.state.unit
    const parts: ReaderDisplayPart[] = []
    this.windowIndexes().forEach((index: number) => {
      (this.map?.item(index)?.parts ?? []).forEach((part: ReaderDisplayPart) => {
        if (!parts.some((other: ReaderDisplayPart) => other.sourceIndex === part.sourceIndex)) parts.push(part)
      })
    })
    if (unit === null) return
    const retained = this.slots.filter((slot: ReaderPageSlot) => slot.kind === this.state.kind &&
      slot.assetPlan === (this.state.kind === 'original' ? this.assetPlans.get(slot.index) ?? null : null) &&
      parts.some((part: ReaderDisplayPart) => part.sourceIndex === slot.index))
    const removed = this.slots.filter((slot: ReaderPageSlot) => !retained.includes(slot))
    this.slots = retained
    removed.forEach((slot: ReaderPageSlot) => slot.session.close())
    const added: ReaderPageSlot[] = []
    parts.forEach((part: ReaderDisplayPart) => {
      if (this.slots.some((slot: ReaderPageSlot) => slot.index === part.sourceIndex)) return
      const slot = new ReaderPageSlot(++this.slotSerial, part.sourceIndex, this.state.kind,
        new ReaderSession(this.catalog, this.assets),
        this.state.kind === 'original' ? this.assetPlans.get(part.sourceIndex) ?? null : null)
      this.slots.push(slot)
      added.push(slot)
    })
    this.emit()
    added.forEach((slot: ReaderPageSlot) => {
      if (!this.slots.includes(slot)) return
      slot.session.subscribe((snapshot: ReaderSnapshot): void => { this.slotChanged(slot, snapshot) })
      void slot.session.openPrepared(unit, slot.index, slot.kind, slot.assetPlan)
    })
  }

  private slotChanged(slot: ReaderPageSlot, snapshot: ReaderSnapshot): void {
    if (this.disposed || !this.slots.includes(slot)) return
    this.requestCrop(slot, snapshot)
    const page = snapshot.page
    if (this.state.phase === 'ready' && page !== null && !this.pages.has(page.sourceIndex)) {
      this.pages.set(page.sourceIndex, page.copy())
      this.rebuild()
    } else this.emit()
  }

  reportPresentation(slotId: number, requestId: number, success: boolean, width: number = 0, height: number = 0): void {
    const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (this.disposed || slot === undefined) return
    const before = slot.session.snapshot()
    if (before.assetRequestId !== requestId || requestId === 0) return
    slot.session.reportPresentation(requestId, success)
    // Native ORIGINAL dimensions, never thumbnail/sprite dimensions, can refine topology.
    const page = this.pages.get(slot.index)
    if (success && slot.session.snapshot().phase === 'displayed' && before.kind === 'original' &&
      page !== undefined && this.state.phase === 'ready' &&
      Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0 &&
      (page.width !== width || page.height !== height)) {
      page.width = width
      page.height = height
      this.rebuild()
    }
  }

  private currentRenderSlot(selectionId: number, slotId: number, requestId: number,
    fragment: ReaderFragment): ReaderPageSlot | undefined {
    if (this.disposed || this.state.phase !== 'ready' || selectionId !== this.state.selectionId) return undefined
    const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.id === slotId)
    if (slot === undefined || requestId === 0 || slot.session.snapshot().assetRequestId !== requestId) return undefined
    return this.map?.item(this.state.displayIndex)?.parts.some((part: ReaderDisplayPart) =>
      part.sourceIndex === slot.index && part.fragment === fragment) ? slot : undefined
  }

  reportRenderFailure(selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void {
    this.currentRenderSlot(selectionId, slotId, requestId, fragment)?.session.reportRenderFailure(requestId)
  }

  /** Cached decode failure is asset evidence, never a reading-position observation. */
  reportCachedRenderFailure(topologyRevision: number, itemKey: string, slotId: number,
    requestId: number, fragment: ReaderFragment): void {
    if (this.disposed || topologyRevision !== this.topologyRevision || this.state.phase !== 'ready') return
    const index = this.displayKeys.indexOf(itemKey)
    const frame = this.framesAt(index).find((candidate: ReaderPagedFrame) =>
      candidate.slotId === slotId && candidate.asset.assetRequestId === requestId && candidate.part.fragment === fragment)
    if (frame !== undefined) this.slots.find((slot: ReaderPageSlot) => slot.id === slotId)?.session.reportRenderFailure(requestId)
  }

  reportVisible(selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): boolean {
    if (!this.active || this.state.phase !== 'ready' || selectionId !== this.state.selectionId ||
      this.state.policy.layout === 'continuous' ||
      this.state.kind !== 'original' || this.state.anchor === null || this.map === null) return false
    const slot = this.currentRenderSlot(selectionId, slotId, requestId, fragment)
    if (slot === undefined) return false
    if (this.cropEnabled && (slot.cropRequestId !== requestId || !slot.cropSettled)) return false
    const asset = slot.session.snapshot()
    const anchor = this.state.anchor
    // A spread's second page decoding first must not change the selected original.
    if (asset.phase !== 'displayed' || asset.assetRequestId !== requestId || asset.page?.key !== anchor.pageKey) return false
    if (this.state.observedSelectionId === selectionId) return true
    this.state.observedAnchor = anchor.copy()
    this.state.observedSelectionId = selectionId
    this.emit()
    return true
  }

  /** Native visible range drives demand, not proof that any original was displayed. */
  setContinuousRange(start: number, end: number, topologyRevision: number, navigationRevision: number): boolean {
    if (!this.active || this.state.phase !== 'ready' || this.state.policy.layout !== 'continuous' ||
      this.map === null || topologyRevision !== this.topologyRevision || navigationRevision !== this.navigationRevision ||
      !Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end < start || end >= this.map.count()) return false
    if (start === this.continuousStart && end === this.continuousEnd) return true
    this.continuousStart = start
    this.continuousEnd = end
    if (this.state.displayIndex !== start) {
      this.cancelOriginalPreparations()
      this.state.displayIndex = start
      this.state.anchor = this.map.anchorAt(start)
      this.state.selectionId += 1
    }
    this.reconcile()
    return true
  }

  /** A measured point on the first visible decoded original; never a total-scroll estimate. */
  reportContinuousVisible(topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, x: number, y: number): boolean {
    if (!this.active || this.state.phase !== 'ready' || this.state.policy.layout !== 'continuous' ||
      this.state.kind !== 'original' || this.map === null || topologyRevision !== this.topologyRevision ||
      navigationRevision !== this.navigationRevision || this.continuousStart < 0 ||
      itemKey !== this.displayKeys[this.continuousStart] || !Number.isFinite(x) || !Number.isFinite(y) ||
      x < 0 || x > 1 || y < 0 || y > 1) return false
    const frame = this.framesAt(this.continuousStart).find((candidate: ReaderPagedFrame) =>
      candidate.slotId === slotId && candidate.asset.assetRequestId === requestId &&
      candidate.asset.phase === 'displayed' && candidate.asset.kind === 'original')
    if (frame === undefined || requestId === 0) return false
    const anchor = this.map.anchorAt(this.continuousStart, 0, x, y)
    if (anchor === null || anchor.pageKey === null) return false
    const previous = this.state.observedAnchor
    if (previous !== null && previous.unit.equals(anchor.unit) && previous.pageKey === anchor.pageKey &&
      previous.x === x && previous.y === y && previous.fragment === 'whole' &&
      this.state.observedSelectionId === this.state.selectionId) return true
    this.state.anchor = anchor.copy()
    this.state.observedAnchor = anchor
    this.state.observedSelectionId = this.state.selectionId
    this.emit()
    return true
  }

  private releaseSlots(): void {
    const slots = this.slots
    this.slots = []
    slots.forEach((slot: ReaderPageSlot) => slot.session.close())
  }

  close(): void {
    this.cancelOriginalPreparations()
    this.assetPlans.clear()
    if (this.disposed) return
    this.disposed = true
    this.active = false
    this.cancellation.cancel()
    this.epoch += 1
    this.releaseSlots()
    this.state.phase = 'closed'
    this.emit()
    this.listener = null
  }
}
