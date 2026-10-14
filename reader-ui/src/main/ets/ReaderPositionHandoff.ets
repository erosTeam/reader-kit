import { ReaderPagedSnapshot } from '@reader-kit/core'
import { ReaderSelectedDrawable } from './ReaderSelectedDrawable'

export type ReaderPositionTargetReadiness = 'drawable' | 'terminal-face' | 'pending' | 'outside-window'

/** One visible-position claim while a native pager change prepares its target.
 * OFF commands project the old image above the native pager; animated cached
 * commands keep the old native cell in place until target decode, then move
 * without that overlay. L1 owns the outgoing asset lease in both modes. */
export class ReaderPositionHandoff {
  readonly serial: number
  readonly topologyRevision: number
  readonly navigationRevision: number
  readonly targetIndex: number
  readonly targetKey: string
  readonly oldKey: string
  readonly oldProjection: ReaderPagedSnapshot
  readonly animated: boolean
  private readonly targetNodeReceipts: Set<string> = new Set<string>()
  private readonly nativeNodeReceipts: Set<string> = new Set<string>()
  private readonly oldStableReceipts: Set<string> = new Set<string>()
  private readonly targetStableReceipts: Set<string> = new Set<string>()
  private readonly nativeStableReceipts: Set<string> = new Set<string>()

  private stablePart(slotId: number, requestId: number, visualRevision: number): string {
    return `${slotId}:${requestId}:${visualRevision}`
  }

  private matchesPart(snapshot: ReaderPagedSnapshot, slotId: number, requestId: number,
    sourceIndex: number, fragment: string, visualRevision: number): boolean {
    return snapshot.frames.some(frame => frame.slotId === slotId &&
      frame.asset.assetRequestId === requestId && frame.asset.visualRevision === visualRevision &&
      frame.part.sourceIndex === sourceIndex && frame.part.fragment === fragment &&
      frame.asset.kind === 'original' && frame.asset.phase === 'displayed')
  }

  oldNodeStable(topology: number, navigation: number, selection: number, slotId: number,
    requestId: number, sourceIndex: number, fragment: string, visualRevision: number): boolean {
    const old = this.oldProjection
    if (topology !== old.topologyRevision || navigation !== old.navigationRevision ||
      selection !== old.selectionId || !this.matchesPart(old, slotId, requestId,
        sourceIndex, fragment, visualRevision)) return false
    this.oldStableReceipts.add(this.stablePart(slotId, requestId, visualRevision))
    return this.oldNodeReady()
  }

  oldNodeReady(): boolean {
    return this.oldProjection.frames.length > 0 && this.oldProjection.frames.every(frame =>
      this.oldStableReceipts.has(this.stablePart(frame.slotId, frame.asset.assetRequestId,
        frame.asset.visualRevision)))
  }

  targetNodeStable(snapshot: ReaderPagedSnapshot, topology: number, navigation: number, selection: number,
    slotId: number, requestId: number, sourceIndex: number, fragment: string,
    visualRevision: number): boolean {
    if (!this.current(this.serial, snapshot) || topology !== snapshot.topologyRevision ||
      navigation !== snapshot.navigationRevision || selection !== snapshot.selectionId) return false
    const target = snapshot.forItem(this.targetKey)
    if (!this.matchesPart(target, slotId, requestId, sourceIndex, fragment, visualRevision)) return false
    this.targetStableReceipts.add(this.stablePart(slotId, requestId, visualRevision))
    return this.targetStableReady(snapshot)
  }

  targetStableReady(snapshot: ReaderPagedSnapshot): boolean {
    const target = snapshot.forItem(this.targetKey)
    return this.targetNodeReady(snapshot) && target.frames.every(frame =>
      this.targetStableReceipts.has(this.stablePart(frame.slotId, frame.asset.assetRequestId,
        frame.asset.visualRevision)))
  }

  nativeNodeStable(snapshot: ReaderPagedSnapshot, key: string, topology: number, navigation: number,
    selection: number, slotId: number, requestId: number, sourceIndex: number,
    fragment: string, visualRevision: number): boolean {
    if (!this.targetSelected(snapshot) || key !== this.targetKey ||
      topology !== snapshot.topologyRevision || navigation !== snapshot.navigationRevision ||
      selection !== snapshot.selectionId) return false
    const target = snapshot.forItem(this.targetKey)
    if (!this.matchesPart(target, slotId, requestId, sourceIndex, fragment, visualRevision)) return false
    this.nativeStableReceipts.add(this.stablePart(slotId, requestId, visualRevision))
    return this.nativeStableReady(snapshot)
  }

  nativeStableReady(snapshot: ReaderPagedSnapshot): boolean {
    const target = snapshot.forItem(this.targetKey)
    return this.nativeNodeReady(snapshot) && target.frames.every(frame =>
      this.nativeStableReceipts.has(this.stablePart(frame.slotId, frame.asset.assetRequestId,
        frame.asset.visualRevision)))
  }

  constructor(serial: number, targetIndex: number, topologyRevision: number, navigationRevision: number,
    snapshot: ReaderPagedSnapshot,
    prior: ReaderPositionHandoff | null = null, animated: boolean = false) {
    this.serial = serial
    this.topologyRevision = topologyRevision
    this.navigationRevision = navigationRevision
    this.targetIndex = targetIndex
    this.targetKey = snapshot.displayKeys[targetIndex]
    this.oldKey = prior?.oldKey ?? snapshot.displayKeys[snapshot.displayIndex]
    this.oldProjection = prior?.oldProjection ?? snapshot.forItem(this.oldKey)
    this.animated = animated
  }

  current(serial: number, snapshot: ReaderPagedSnapshot): boolean {
    return this.serial === serial && this.topologyRevision === snapshot.topologyRevision &&
      this.targetKey === snapshot.displayKeys[this.targetIndex]
  }

  /** Decode readiness for the reserved original target before logical selection.
   * A missing frame is pending, not permission to expose an unprepared native cell. */
  targetReadiness(snapshot: ReaderPagedSnapshot): ReaderPositionTargetReadiness {
    if (!this.current(this.serial, snapshot) || snapshot.kind !== 'original') return 'outside-window'
    const target = snapshot.forItem(this.targetKey)
    if (target.frames.length === 0) return 'pending'
    if (ReaderSelectedDrawable.from(target) !== null) return 'drawable'
    if (target.frames.every(frame => frame.asset.phase === 'displayed' || frame.asset.phase === 'failed' ||
      (frame.asset.phase === 'suppressed' && frame.asset.notice !== null)) &&
      target.frames.some(frame => frame.asset.phase === 'failed' || frame.asset.phase === 'suppressed')) return 'terminal-face'
    return 'pending'
  }

  /** Only this mounted L2 target viewport's Image callback may ready its visual layer. */
  targetNodePresented(snapshot: ReaderPagedSnapshot, slotId: number, requestId: number, success: boolean): boolean {
    if (!success || !this.current(this.serial, snapshot) ||
      snapshot.navigationRevision !== this.navigationRevision) return false
    const target = snapshot.forItem(this.targetKey)
    if (!target.frames.some(frame => frame.slotId === slotId && frame.asset.assetRequestId === requestId)) return false
    this.targetNodeReceipts.add(`${slotId}:${requestId}`)
    return this.targetNodeReady(snapshot)
  }

  targetTerminalMounted(snapshot: ReaderPagedSnapshot, slotId: number, requestId: number): boolean {
    if (!this.current(this.serial, snapshot) || snapshot.navigationRevision !== this.navigationRevision) return false
    const target = snapshot.forItem(this.targetKey)
    if (!target.frames.some(frame => frame.slotId === slotId && frame.asset.assetRequestId === requestId &&
      (frame.asset.phase === 'failed' ||
        (frame.asset.phase === 'suppressed' && frame.asset.notice !== null)))) return false
    this.targetNodeReceipts.add(`${slotId}:${requestId}`)
    return this.targetNodeReady(snapshot)
  }

  targetNodeReady(snapshot: ReaderPagedSnapshot): boolean {
    if (!this.current(this.serial, snapshot) || snapshot.navigationRevision !== this.navigationRevision) return false
    const target = snapshot.forItem(this.targetKey)
    return target.frames.length > 0 && target.frames.every(frame =>
      this.targetNodeReceipts.has(`${frame.slotId}:${frame.asset.assetRequestId}`))
  }

  /** The native Swiper child has its own decode receipts, separate from L2 preparation. */
  nativeNodePresented(snapshot: ReaderPagedSnapshot, key: string, slotId: number,
    requestId: number, success: boolean): boolean {
    if (!success || key !== this.targetKey || !this.current(this.serial, snapshot)) return false
    const target = snapshot.forItem(this.targetKey)
    if (!target.frames.some(frame => frame.slotId === slotId && frame.asset.assetRequestId === requestId)) return false
    this.nativeNodeReceipts.add(`${slotId}:${requestId}`)
    return this.nativeNodeReady(snapshot)
  }

  nativeTerminalMounted(snapshot: ReaderPagedSnapshot, key: string, slotId: number, requestId: number): boolean {
    if (key !== this.targetKey || !this.current(this.serial, snapshot)) return false
    const target = snapshot.forItem(this.targetKey)
    if (!target.frames.some(frame => frame.slotId === slotId && frame.asset.assetRequestId === requestId &&
      (frame.asset.phase === 'failed' ||
        (frame.asset.phase === 'suppressed' && frame.asset.notice !== null)))) return false
    this.nativeNodeReceipts.add(`${slotId}:${requestId}`)
    return this.nativeNodeReady(snapshot)
  }

  nativeNodeReady(snapshot: ReaderPagedSnapshot): boolean {
    if (!this.targetSelected(snapshot)) return false
    const target = snapshot.forItem(this.targetKey)
    return target.frames.length > 0 && target.frames.every(frame =>
      this.nativeNodeReceipts.has(`${frame.slotId}:${frame.asset.assetRequestId}`))
  }

  targetSelected(snapshot: ReaderPagedSnapshot): boolean {
    return this.current(this.serial, snapshot) && snapshot.displayIndex === this.targetIndex &&
      snapshot.navigationRevision > this.navigationRevision
  }

  /** A selected original anchor alone is insufficient for a two-part spread. */
  targetDrawable(key: string, selectionId: number, snapshot: ReaderPagedSnapshot): boolean {
    if (!this.current(this.serial, snapshot) || key !== this.targetKey ||
      snapshot.displayIndex !== this.targetIndex || selectionId !== snapshot.selectionId ||
      snapshot.navigationRevision <= this.navigationRevision) return false
    const frames = snapshot.forItem(key).frames
    return frames.length > 0 && frames.every(frame =>
      frame.asset.phase === 'displayed' && frame.asset.uri.length > 0)
  }
}
