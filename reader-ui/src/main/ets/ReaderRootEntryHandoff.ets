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

  reset(): void {
    this.entryId = -1
    this.flightStarted = false
    this.revealStarted = false
  }

  openingStarted(): boolean { return this.flightStarted }
  revealStartedForEntry(): boolean { return this.revealStarted }

  private observe(entry: ReaderEntryTransition): void {
    if (this.entryId === entry.entryId) return
    this.entryId = entry.entryId
    this.flightStarted = false
    this.revealStarted = false
  }

  /** Start the retained source proxy only after the actual selected part is laid out. */
  sync(entry: ReaderEntryTransition | null, active: boolean, readerContentWaiting: boolean,
    host: ReaderRootEntryHandoffHost): void {
    if (entry === null || !active) return
    this.observe(entry)
    const target = entry.target
    if (entry.phase === 'layout') {
      if (target === null || !target.geometryReady || !target.contentRect.valid() || this.flightStarted) return
      this.flightStarted = true
      if (!host.authorizeDeparture(entry) || !host.setOpeningTarget(target)) {
        entry.cancel()
        host.startOpening(null)
        return
      }
      entry.beginMove()
      host.startOpening((): void => {
        if (this.entryId === entry.entryId && entry.phase === 'moving') entry.arrived()
      })
      return
    }
    if (entry.phase !== 'waiting' || target === null || !target.decodedReady ||
      !readerContentWaiting || this.revealStarted) return
    this.revealStarted = true
    host.revealOriginal((): void => {
      if (this.entryId !== entry.entryId || entry.phase !== 'waiting') return
      entry.reveal()
    }, (): void => {
      if (this.entryId !== entry.entryId || entry.phase !== 'revealing') return
      entry.finish()
      host.notifyReaderImageReady(target.part.sourceIndex + 1)
    })
  }

  /** A later geometry cancellation must retain the already-owned root flight, never signal decode. */
  startCancelledFlight(entry: ReaderEntryTransition | null, active: boolean,
    host: ReaderRootEntryHandoffHost): void {
    if (entry === null || entry.phase !== 'cancelled' || !active) return
    this.observe(entry)
    if (this.flightStarted) return
    this.flightStarted = true
    host.startOpening(null)
  }
}
