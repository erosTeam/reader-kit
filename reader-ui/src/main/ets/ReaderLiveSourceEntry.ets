import { ReaderPagedSnapshot } from '@reader-kit/core'
import { ReaderSelectedDrawable } from './ReaderSelectedDrawable'

/** L2 owner for an entry whose real source remains mounted in the host.
 * The host supplies the source pixels and route effects; it never decides
 * whether a decoded Reader part may take over the visible frame. */
export class ReaderLiveSourceEntry {
  private phase: 'holding' | 'revealing' | 'released' | 'failed' | 'cancelled' = 'holding'
  private claim: ReaderSelectedDrawable | null = null
  private nativeEpoch: string = ''
  private nativeParts: Set<string> = new Set<string>()

  private epoch(snapshot: ReaderPagedSnapshot): string {
    return `${snapshot.unit?.key.scope ?? ''}:${snapshot.unit?.key.work ?? ''}:` +
      `${snapshot.unit?.key.unit ?? ''}:${snapshot.topologyRevision}:${snapshot.navigationRevision}:` +
      `${snapshot.displayIndex}:${snapshot.displayKeys[snapshot.displayIndex] ?? ''}`
  }

  private part(slotId: number, requestId: number, sourceIndex: number, fragment: string): string {
    return `${slotId}:${requestId}:${sourceIndex}:${fragment}`
  }

  /** A current native Image finished again with the decoded page's real geometry. */
  recordNativeReady(snapshot: ReaderPagedSnapshot, slotId: number, requestId: number,
    sourceIndex: number, fragment: string, width: number, height: number): boolean {
    if (this.phase !== 'holding' || width <= 0 || height <= 0) return false
    const frame = snapshot.frames.find(candidate => candidate.slotId === slotId &&
      candidate.asset.assetRequestId === requestId && candidate.part.sourceIndex === sourceIndex &&
      candidate.part.fragment === fragment && candidate.asset.kind === 'original' &&
      candidate.asset.phase === 'displayed' && candidate.asset.page?.width === width &&
      candidate.asset.page?.height === height)
    if (frame === undefined) return false
    const epoch = this.epoch(snapshot)
    if (this.nativeEpoch !== epoch) {
      this.nativeEpoch = epoch
      this.nativeParts.clear()
    }
    this.nativeParts.add(this.part(slotId, requestId, sourceIndex, fragment))
    return true
  }

  offer(snapshot: ReaderPagedSnapshot): ReaderSelectedDrawable | null {
    if (this.phase !== 'holding') return null
    const claim = ReaderSelectedDrawable.from(snapshot)
    if (claim === null || this.nativeEpoch !== this.epoch(snapshot) ||
      !snapshot.frames.every(frame => this.nativeParts.has(this.part(frame.slotId,
        frame.asset.assetRequestId, frame.part.sourceIndex, frame.part.fragment)))) return null
    return claim
  }

  reveal(claim: ReaderSelectedDrawable, snapshot: ReaderPagedSnapshot): boolean {
    if (this.phase !== 'holding' || !claim.current(snapshot)) return false
    this.claim = claim
    this.phase = 'revealing'
    return true
  }

  /** A superseding selection/request must return visible ownership to the live host. */
  reconcile(snapshot: ReaderPagedSnapshot): boolean {
    if (this.phase !== 'revealing' || this.claim?.current(snapshot) === true) return false
    this.claim = null
    this.phase = 'holding'
    this.nativeEpoch = ''
    this.nativeParts.clear()
    return true
  }

  observedRevealFrame(claim: ReaderSelectedDrawable, snapshot: ReaderPagedSnapshot): boolean {
    if (this.phase !== 'revealing' || this.claim?.key() !== claim.key() || !claim.current(snapshot)) return false
    this.phase = 'released'
    return true
  }

  fail(): boolean {
    if (this.phase !== 'holding') return false
    this.phase = 'failed'
    return true
  }

  cancel(): void { this.phase = 'cancelled' }

  readerVisible(): boolean { return this.phase === 'revealing' || this.phase === 'released' }
  hostRetained(): boolean { return this.phase === 'holding' || this.phase === 'revealing' }
}
