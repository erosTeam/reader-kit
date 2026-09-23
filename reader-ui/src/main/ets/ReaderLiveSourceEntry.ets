import { ReaderPagedSnapshot } from '@reader-kit/core'
import { ReaderSelectedDrawable } from './ReaderSelectedDrawable'

/** L2 owner for an entry whose real source remains mounted in the host.
 * The host supplies the source pixels and route effects; it never decides
 * whether a decoded Reader part may take over the visible frame. */
export class ReaderLiveSourceEntry {
  private phase: 'holding' | 'revealing' | 'released' | 'failed' | 'cancelled' = 'holding'
  private claim: ReaderSelectedDrawable | null = null

  offer(snapshot: ReaderPagedSnapshot): ReaderSelectedDrawable | null {
    if (this.phase !== 'holding') return null
    return ReaderSelectedDrawable.from(snapshot)
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
