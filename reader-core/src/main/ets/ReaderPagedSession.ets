import { ReaderUnitKey, ReaderUnit, ReaderPage } from './ReaderContent'
import {
  ReaderSession, ReaderSnapshot, ReaderCatalog, ReaderAssetProvider, ReaderAssetKind, ReaderCancellation,
} from './ReaderSession'
import { ReaderDisplayMap, ReaderDisplayPolicy, ReaderDisplayPart, ReaderReadingAnchor, ReaderFragment } from './ReaderDisplayMap'

export class ReaderPagedFrame {
  slotId: number
  part: ReaderDisplayPart
  asset: ReaderSnapshot

  constructor(slotId: number, part: ReaderDisplayPart, asset: ReaderSnapshot) {
    this.slotId = slotId
    this.part = part.copy()
    this.asset = asset.copy()
  }
}

export class ReaderPagedSnapshot {
  unit: ReaderUnit | null = null
  phase: 'idle' | 'catalog' | 'ready' | 'failed' | 'closed' = 'idle'
  error: string = ''
  policy: ReaderDisplayPolicy = new ReaderDisplayPolicy()
  kind: ReaderAssetKind = 'original'
  displayIndex: number = 0
  displayCount: number = 0
  selectionId: number = 0
  /** The commanded/restored location is not evidence that its pixels were seen. */
  anchor: ReaderReadingAnchor | null = null
  observedAnchor: ReaderReadingAnchor | null = null
  observedSelectionId: number = 0
  frames: ReaderPagedFrame[] = []
  canPreviousUnit: boolean = false
  canNextUnit: boolean = false
}

class ReaderPageSlot {
  id: number
  index: number
  kind: ReaderAssetKind
  session: ReaderSession

  constructor(id: number, index: number, kind: ReaderAssetKind, session: ReaderSession) {
    this.id = id
    this.index = index
    this.kind = kind
    this.session = session
  }
}

/**
 * One display/anchor owner, at most two asset slots. ReaderSession continues to
 * own each request, decoder fence and lease; hosts still own chapter semantics.
 * Metadata is discovered only for selected parts, never by opening every page.
 */
export class ReaderPagedSession {
  private readonly catalog: ReaderCatalog
  private readonly assets: ReaderAssetProvider
  private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  private map: ReaderDisplayMap | null = null
  private pages: Map<number, ReaderPage> = new Map()
  private slots: ReaderPageSlot[] = []
  private slotSerial: number = 0
  private epoch: number = 0
  private cancellation: ReaderCancellation = new ReaderCancellation()
  private pendingUnit: ReaderUnitKey | null = null
  private pendingIndex: number = 0
  private disposed: boolean = false
  private active: boolean = false
  private listener: ((snapshot: ReaderPagedSnapshot) => void) | null = null

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider) {
    this.catalog = catalog
    this.assets = assets
  }

  cancellationMode(): string { return this.assets.cancellationMode }
  setViewportActive(active: boolean): void { this.active = active && !this.disposed }
  subscribe(listener: (snapshot: ReaderPagedSnapshot) => void): void {
    this.listener = listener
    this.emit()
  }

  snapshot(): ReaderPagedSnapshot {
    const value = new ReaderPagedSnapshot()
    value.unit = this.state.unit?.copy() ?? null
    value.phase = this.state.phase
    value.error = this.state.error
    value.policy = this.state.policy.copy()
    value.kind = this.state.kind
    value.displayIndex = this.state.displayIndex
    value.displayCount = this.map?.count() ?? 0
    value.selectionId = this.state.selectionId
    value.anchor = this.state.anchor?.copy() ?? null
    value.observedAnchor = this.state.observedAnchor?.copy() ?? null
    value.observedSelectionId = this.state.observedSelectionId
    value.canPreviousUnit = this.state.canPreviousUnit
    value.canNextUnit = this.state.canNextUnit
    const parts = this.map?.item(this.state.displayIndex)?.visualParts(this.state.policy.direction) ?? []
    value.frames = parts.filter((part: ReaderDisplayPart) =>
      this.slots.some((slot: ReaderPageSlot) => slot.index === part.sourceIndex))
      .map((part: ReaderDisplayPart): ReaderPagedFrame => {
      const slot = this.slots.find((candidate: ReaderPageSlot) => candidate.index === part.sourceIndex)
      const asset = slot?.session.snapshot() ?? new ReaderSnapshot()
      const page = this.pages.get(part.sourceIndex)
      if (page !== undefined && asset.page !== null) asset.page = page.copy()
      return new ReaderPagedFrame(slot?.id ?? 0, part, asset)
    })
    return value
  }

  private emit(): void { if (this.listener !== null) this.listener(this.snapshot()) }

  async open(key: ReaderUnitKey, index: number = 0): Promise<void> {
    if (this.disposed) return
    this.cancellation.cancel()
    this.cancellation = new ReaderCancellation()
    const cancellation = this.cancellation
    const epoch = ++this.epoch
    const target = key.copy()
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
      this.pages.clear()
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
    // No UI may advertise continuous scrolling through a paged-only controller.
    if (policy.layout === 'continuous' || !Number.isFinite(policy.widePageRatio) || policy.widePageRatio <= 1) {
      throw new Error('reader_unsupported_paged_policy')
    }
    this.state.policy = policy.copy()
    if (this.state.phase === 'ready') this.rebuild()
    else this.emit()
  }

  move(direction: 'next' | 'previous'): void {
    if (this.disposed || this.state.phase !== 'ready' || this.map === null) return
    const next = this.map.neighbor(this.state.displayIndex, direction)
    if (next === null) return
    this.state.anchor = this.map.anchorAt(next)
    this.rebuild()
  }

  setAssetKind(kind: ReaderAssetKind): void {
    if (this.disposed || this.state.phase !== 'ready' || kind === this.state.kind) return
    if (kind === 'thumbnail' && this.snapshot().frames.some((frame: ReaderPagedFrame) =>
      frame.asset.page === null || !frame.asset.page.thumbnail.available)) return
    this.state.kind = kind
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
    else await Promise.all(this.slots.filter((slot: ReaderPageSlot) => slot.session.snapshot().phase === 'failed')
      .map((slot: ReaderPageSlot) => slot.session.retry()))
  }

  private rebuild(): void {
    if (this.state.unit === null || this.state.anchor === null) return
    this.map = new ReaderDisplayMap(this.state.unit, Array.from(this.pages.values()), this.state.policy)
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
    const parts = this.map?.item(this.state.displayIndex)?.parts ?? []
    if (unit === null) return
    const retained = this.slots.filter((slot: ReaderPageSlot) => slot.kind === this.state.kind &&
      parts.some((part: ReaderDisplayPart) => part.sourceIndex === slot.index))
    const removed = this.slots.filter((slot: ReaderPageSlot) => !retained.includes(slot))
    this.slots = retained
    removed.forEach((slot: ReaderPageSlot) => slot.session.close())
    const added: ReaderPageSlot[] = []
    parts.forEach((part: ReaderDisplayPart) => {
      if (this.slots.some((slot: ReaderPageSlot) => slot.index === part.sourceIndex)) return
      const slot = new ReaderPageSlot(++this.slotSerial, part.sourceIndex, this.state.kind,
        new ReaderSession(this.catalog, this.assets))
      this.slots.push(slot)
      added.push(slot)
    })
    this.emit()
    added.forEach((slot: ReaderPageSlot) => {
      slot.session.subscribe((snapshot: ReaderSnapshot): void => { this.slotChanged(slot, snapshot) })
      void slot.session.openPrepared(unit, slot.index, slot.kind)
    })
  }

  private slotChanged(slot: ReaderPageSlot, snapshot: ReaderSnapshot): void {
    if (this.disposed || !this.slots.includes(slot)) return
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

  reportVisible(selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): boolean {
    if (!this.active || this.state.phase !== 'ready' || selectionId !== this.state.selectionId ||
      this.state.kind !== 'original' || this.state.anchor === null || this.map === null) return false
    const slot = this.currentRenderSlot(selectionId, slotId, requestId, fragment)
    if (slot === undefined) return false
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

  private releaseSlots(): void {
    const slots = this.slots
    this.slots = []
    slots.forEach((slot: ReaderPageSlot) => slot.session.close())
  }

  close(): void {
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
