import { ReaderImageShareHost, ReaderImageShareTarget, ReaderImageSharePresentation,
  ReaderCancellation } from '@reader-kit/core'

/** Explicit Debug Want only; preserves the real host payload and never sends it. */
export class ReaderLabShareProbe implements ReaderImageShareHost {
  private host: ReaderImageShareHost
  private mode: string
  private injected: boolean = false

  constructor(host: ReaderImageShareHost, mode: string) { this.host = host; this.mode = mode }

  async prepare(target: ReaderImageShareTarget, cancellation: ReaderCancellation): Promise<ReaderImageSharePresentation> {
    const inject = !this.injected && (this.mode === 'fail-once' || this.mode === 'delay-once')
    if (inject) this.injected = true
    const presentation = await this.host.prepare(target, cancellation)
    if (inject && this.mode === 'fail-once') {
      presentation.release()
      console.info(`[ReaderLabShareProbe] prepare_failure source=${target.sourceIndex}`)
      throw new Error('reader_lab_share_prepare_failure')
    }
    if (inject && this.mode === 'delay-once') {
      console.info(`[ReaderLabShareProbe] prepare_delay source=${target.sourceIndex}`)
      await new Promise<void>((resolve): void => { setTimeout(resolve, 3000) })
      // Deliberately returns a late result: the real core must retire it itself.
      console.info(`[ReaderLabShareProbe] delayed_result source=${target.sourceIndex} cancelled=${cancellation.isCancelled()}`)
    }
    return presentation
  }
}
