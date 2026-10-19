import { ReaderPagedSnapshot } from '@reader-kit/core'
import { ReaderEntryTarget, ReaderEntryTransition } from './ReaderEntryTransition'

/**
 * Narrow host bridge for the root-owned thumbnail proxy. Hosts retain their
 * window and navigation mechanisms; reader-kit owns the entry-phase decisions
 * and guarantees each departure, flight, reveal and completion runs once.
 */
export interface ReaderRootEntryHandoffHost {
  authorizeDeparture(entry: ReaderEntryTransition): boolean
  setOpeningTarget(target: ReaderEntryTarget): boolean
  startOpening(onArrived: (() => void) | null): void
  revealOriginal(commitReveal: () => void, onFinished: () => void): void
  notifyReaderImageReady(page: number): void
}

export class ReaderRootEntryHandoff {
  private entryId: number = -1
  private flightStarted: boolean = false
  private revealStarted: boolean = false
  private contentNotified: boolean = false
  private reverseRequested: boolean = false

  reset(): void {
    this.entryId = -1
    this.flightStarted = false
    this.revealStarted = false
    this.contentNotified = false
    this.reverseRequested = false
  }

  openingStarted(): boolean { return this.flightStarted }
  revealStartedForEntry(): boolean { return this.revealStarted }

  private observe(entry: ReaderEntryTransition): void {
    if (this.entryId === entry.entryId) return
    this.entryId = entry.entryId
    this.flightStarted = false
    this.revealStarted = false
    this.contentNotified = false
    this.reverseRequested = false
  }

  /** Back owns the same entry immediately, before a host's asynchronous close preparation. */
  requestReverse(entry: ReaderEntryTransition | null, active: boolean, reverseProxy: () => boolean): boolean {
    if (!active) return false
    if (entry !== null) this.observe(entry)
    if (this.reverseRequested) return true
    if (!reverseProxy()) return false
    this.reverseRequested = true
    // Fence late forward arrival/reveal callbacks at their existing phase checks.
    entry?.releaseNeighbor()
    entry?.cancel()
    return true
  }

  /** Start the retained source proxy only after the actual selected part is laid out. */
  sync(entry: ReaderEntryTransition | null, active: boolean, readerContentWaiting: boolean,
    host: ReaderRootEntryHandoffHost, snapshot: ReaderPagedSnapshot | null = null): void {
    if (entry === null || !active || this.reverseRequested) return
    this.observe(entry)
    if (entry.phase === 'cancelled') {
      if (!readerContentWaiting || this.contentNotified || snapshot === null ||
        !entry.hasObservedInitialContent(snapshot)) return
      this.contentNotified = true
      host.notifyReaderImageReady(entry.requestedPart.sourceIndex + 1)
      return
    }
    const target = entry.target
    if (entry.phase === 'layout') {
      if (target === null || !target.geometryReady || !target.contentRect.valid() || this.flightStarted) return
      this.flightStarted = true
      if (!host.authorizeDeparture(entry) || !host.setOpeningTarget(target)) {
        entry.cancel()
        host.startOpening(null)
        return
      }
      entry.holdNeighborUntilArrival()
      entry.beginMove()
      host.startOpening((): void => {
        if (this.entryId === entry.entryId && !this.reverseRequested &&
          (entry.phase === 'moving' || entry.phase === 'cancelled')) entry.arrived()
      })
      return
    }
    if (entry.phase !== 'waiting' || target === null || !target.decodedReady ||
      !readerContentWaiting || this.revealStarted) return
    this.revealStarted = true
    host.revealOriginal((): void => {
      if (this.entryId !== entry.entryId || this.reverseRequested || entry.phase !== 'waiting') return
      entry.reveal()
    }, (): void => {
      if (this.entryId !== entry.entryId || this.reverseRequested || entry.phase !== 'revealing') return
      entry.finish()
      this.contentNotified = true
      host.notifyReaderImageReady(target.part.sourceIndex + 1)
    })
  }

  /** A later geometry cancellation must retain the already-owned root flight, never signal decode. */
  startCancelledFlight(entry: ReaderEntryTransition | null, active: boolean,
    host: ReaderRootEntryHandoffHost): void {
    if (entry === null || entry.phase !== 'cancelled' || !active || this.reverseRequested) return
    this.observe(entry)
    if (this.flightStarted) return
    this.flightStarted = true
    host.startOpening(null)
  }
}
