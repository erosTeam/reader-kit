import { inputConsumer, KeyCode, KeyEvent, Action } from '@kit.InputKit'
import { ReaderInputPort, ReaderMoveIntent } from '@reader-kit/core'

/** Platform adapter owned by the host route, not by the reading session. */
export class ReaderVolumeKeys {
  private input: ReaderInputPort
  private active: boolean = false
  private reversed: boolean = false
  private epoch: number = 0
  private down: ((event: KeyEvent) => void) | null = null
  private up: ((event: KeyEvent) => void) | null = null

  constructor(input: ReaderInputPort) { this.input = input }

  setActive(active: boolean, reversed: boolean = false): boolean {
    this.reversed = reversed
    if (!active) { this.close(); return false }
    if (this.active) return true
    this.close()
    if (this.down !== null || this.up !== null) return false
    const epoch = ++this.epoch
    this.down = (event: KeyEvent): void => { this.dispatch(event, epoch, 'next') }
    this.up = (event: KeyEvent): void => { this.dispatch(event, epoch, 'previous') }
    try {
      inputConsumer.on('keyPressed', { key: KeyCode.KEYCODE_VOLUME_DOWN, action: Action.DOWN, isRepeat: false }, this.down)
      inputConsumer.on('keyPressed', { key: KeyCode.KEYCODE_VOLUME_UP, action: Action.DOWN, isRepeat: false }, this.up)
      this.active = true
      console.info('[ReaderVolumeKeys] registered')
      return true
    } catch (error) {
      console.warn(`[ReaderVolumeKeys] registration_failed ${(error as Error).message}`)
      this.close()
      return false
    }
  }

  private dispatch(event: KeyEvent, epoch: number, intent: ReaderMoveIntent): void {
    if (!this.active || epoch !== this.epoch || event.action !== Action.DOWN) return
    const mapped = this.reversed ? (intent === 'next' ? 'previous' : 'next') : intent
    const accepted = this.input.move(mapped)
    console.info(`[ReaderVolumeKeys] intent=${mapped} accepted=${accepted}`)
  }

  close(): void {
    this.active = false
    this.epoch += 1
    // Release each exact callback independently; never remove another route's subscriptions.
    if (this.down !== null) {
      try { inputConsumer.off('keyPressed', this.down); this.down = null }
      catch (error) { console.warn(`[ReaderVolumeKeys] release_down_failed ${(error as Error).message}`) }
    }
    if (this.up !== null) {
      try { inputConsumer.off('keyPressed', this.up); this.up = null }
      catch (error) { console.warn(`[ReaderVolumeKeys] release_up_failed ${(error as Error).message}`) }
    }
    console.info(`[ReaderVolumeKeys] released=${this.down === null && this.up === null}`)
  }
}
