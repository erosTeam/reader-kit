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

  /** Decode readiness for a cached original target, before logical selection changes.
   * A distant target outside L1's native window cannot be held on this signal. */
  targetReadiness(snapshot: ReaderPagedSnapshot): ReaderPositionTargetReadiness {
    if (!this.current(this.serial, snapshot) || snapshot.kind !== 'original') return 'outside-window'
    const target = snapshot.forItem(this.targetKey)
    if (target.frames.length === 0) return 'outside-window'
    if (ReaderSelectedDrawable.from(target) !== null) return 'drawable'
    if (target.frames.every(frame => frame.asset.phase === 'displayed' || frame.asset.phase === 'failed' ||
      frame.asset.phase === 'suppressed') &&
      target.frames.some(frame => frame.asset.phase === 'failed' || frame.asset.phase === 'suppressed')) return 'terminal-face'
    return 'pending'
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
