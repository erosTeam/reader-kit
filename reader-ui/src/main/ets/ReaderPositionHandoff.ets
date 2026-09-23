import { ReaderPagedSnapshot } from '@reader-kit/core'

/** One visible-position claim while a native OFF pager change prepares its target.
 * This owns no asset: L1 keeps the outgoing slot leased until a target-visible
 * report is forwarded after the old visual claim has left the component tree. */
export class ReaderPositionHandoff {
  readonly serial: number
  readonly topologyRevision: number
  readonly navigationRevision: number
  readonly targetIndex: number
  readonly targetKey: string
  readonly oldKey: string
  readonly oldProjection: ReaderPagedSnapshot

  constructor(serial: number, targetIndex: number, topologyRevision: number, navigationRevision: number,
    snapshot: ReaderPagedSnapshot,
    prior: ReaderPositionHandoff | null = null) {
    this.serial = serial
    this.topologyRevision = topologyRevision
    this.navigationRevision = navigationRevision
    this.targetIndex = targetIndex
    this.targetKey = snapshot.displayKeys[targetIndex]
    this.oldKey = prior?.oldKey ?? snapshot.displayKeys[snapshot.displayIndex]
    this.oldProjection = prior?.oldProjection ?? snapshot.forItem(this.oldKey)
  }

  current(serial: number, snapshot: ReaderPagedSnapshot): boolean {
    return this.serial === serial && this.topologyRevision === snapshot.topologyRevision &&
      this.targetKey === snapshot.displayKeys[this.targetIndex]
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
