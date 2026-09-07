import { ReaderDisplayPart, ReaderPagedSnapshot, ReaderPagedFrame } from '@reader-kit/core'

/** Actual laid-out image bounds in window vp, not a gallery's duplicate pager calculation. */
export class ReaderEntryRect {
  x: number
  y: number
  width: number
  height: number
  constructor(x: number = 0, y: number = 0, width: number = 0, height: number = 0) {
    this.x = x; this.y = y; this.width = width; this.height = height
  }

  valid(): boolean {
    return Number.isFinite(this.x) && Number.isFinite(this.y) && Number.isFinite(this.width) &&
      Number.isFinite(this.height) && this.width > 0 && this.height > 0
  }

  copy(): ReaderEntryRect { return new ReaderEntryRect(this.x, this.y, this.width, this.height) }
}

export class ReaderEntryTarget {
  part: ReaderDisplayPart
  selectionId: number = 0
  topologyRevision: number = 0
  navigationRevision: number = 0
  slotId: number = 0
  assetRequestId: number = 0
  layoutRevision: number = 0
  contentRect: ReaderEntryRect = new ReaderEntryRect()
  geometryReady: boolean = false
  decodedReady: boolean = false
  failed: boolean = false

  constructor(part: ReaderDisplayPart) { this.part = part.copy() }

  copy(): ReaderEntryTarget {
    const value = new ReaderEntryTarget(this.part)
    value.selectionId = this.selectionId
    value.topologyRevision = this.topologyRevision
    value.navigationRevision = this.navigationRevision
    value.slotId = this.slotId
    value.assetRequestId = this.assetRequestId
    value.layoutRevision = this.layoutRevision
    value.contentRect = this.contentRect.copy()
    value.geometryReady = this.geometryReady
    value.decodedReady = this.decodedReady
    value.failed = this.failed
    return value
  }
}

export type ReaderEntryPhase = 'layout' | 'moving' | 'waiting' | 'revealing' | 'finished' | 'cancelled'

/** One optional entry only. No navigation, page pairing, progress or snapshot ownership. */
@ObservedV2
export class ReaderEntryTransition {
  readonly entryId: number
  readonly requestedPart: ReaderDisplayPart
  @Trace target: ReaderEntryTarget | null = null
  @Trace phase: ReaderEntryPhase = 'layout'
  @Trace selectedOpacity: number = 0
  @Trace neighborOpacity: number = 0
  private navigation: number = -1
  private selection: number = -1
  private topology: number = -1
  private slot: number = -1
  private request: number = -1

  constructor(entryId: number, requestedPart: ReaderDisplayPart) {
    this.entryId = entryId
    this.requestedPart = requestedPart.copy()
  }

  pending(): boolean { return this.phase !== 'finished' && this.phase !== 'cancelled' }

  matches(part: ReaderDisplayPart): boolean {
    return part.unit.equals(this.requestedPart.unit) && part.sourceIndex === this.requestedPart.sourceIndex &&
      part.fragment === this.requestedPart.fragment &&
      (this.requestedPart.pageKey === null || part.pageKey === this.requestedPart.pageKey)
  }

  /** Called by the actual session owner before any child layout/decode callback. */
  update(snapshot: ReaderPagedSnapshot): void {
    if (!this.pending() || snapshot.phase === 'idle' || snapshot.phase === 'catalog') return
    const frame = snapshot.frames.find((value: ReaderPagedFrame): boolean => this.matches(value.part))
    if (snapshot.phase !== 'ready' || frame === undefined) {
      this.cancel(); return
    }
    if (this.navigation >= 0 && this.navigation !== snapshot.navigationRevision) {
      this.cancel(); return
    }
    if (this.phase !== 'layout' && this.slot >= 0 &&
      (this.slot !== frame.slotId || this.request !== frame.asset.assetRequestId)) {
      this.cancel(); return
    }
    if (this.selection !== snapshot.selectionId || this.topology !== snapshot.topologyRevision ||
      this.slot !== frame.slotId || this.request !== frame.asset.assetRequestId) this.target = null
    this.navigation = snapshot.navigationRevision
    this.selection = snapshot.selectionId
    this.topology = snapshot.topologyRevision
    this.slot = frame.slotId
    this.request = frame.asset.assetRequestId
  }

  publishTarget(value: ReaderEntryTarget): void {
    if (!this.pending() || !this.matches(value.part) || value.navigationRevision !== this.navigation ||
      value.selectionId !== this.selection || value.topologyRevision !== this.topology ||
      value.slotId !== this.slot || value.assetRequestId !== this.request) return
    const previous = this.target
    if (previous !== null && value.layoutRevision < previous.layoutRevision) return
    this.target = value.copy()
    if (value.failed) this.cancel()
  }

  opacity(part: ReaderDisplayPart): number {
    return this.matches(part) ? this.selectedOpacity : this.neighborOpacity
  }

  /** Only the presenter advances these phases after the corresponding animation completes. */
  beginMove(): void {
    if (this.phase === 'layout') {
      this.phase = 'moving'
      console.info(`[ReaderEntry] id=${this.entryId} phase=moving source=${this.requestedPart.sourceIndex}`)
    }
  }
  arrived(): void {
    if (this.phase === 'moving') {
      this.phase = 'waiting'; this.neighborOpacity = 1
      console.info(`[ReaderEntry] id=${this.entryId} phase=waiting`)
    }
  }
  reveal(): void {
    if (this.phase === 'waiting' && this.target?.decodedReady === true) {
      this.phase = 'revealing'; this.selectedOpacity = 1
      console.info(`[ReaderEntry] id=${this.entryId} phase=revealing`)
    }
  }
  finish(): void {
    if (this.phase === 'revealing') {
      this.phase = 'finished'; this.selectedOpacity = 1; this.neighborOpacity = 1
      console.info(`[ReaderEntry] id=${this.entryId} phase=finished`)
    }
  }
  cancel(): void {
    if (!this.pending()) return
    console.info(`[ReaderEntry] id=${this.entryId} cancelled_from=${this.phase}`)
    this.phase = 'cancelled'; this.selectedOpacity = 1; this.neighborOpacity = 1
  }
}
