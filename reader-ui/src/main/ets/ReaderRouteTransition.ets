import { UIContext } from '@kit.ArkUI'

/** Ordinary native-route entry only. Thumbnail flights retain their own owner.
 * Window admission requires both the real animation and native transition end.
 * A platform timeout is a failure bound, never evidence that animation finished.
 */
@ObservedV2
export class ReaderRouteTransition {
  @Trace progress: number = 1
  @Trace phase: string = 'idle'
  private epoch: number = 0
  private animationFinished: boolean = false

  begin(): void {
    this.epoch += 1
    this.animationFinished = false
    this.progress = 0
    this.phase = 'armed'
    this.observe('armed')
  }

  skip(): void {
    this.epoch += 1
    this.animationFinished = false
    this.progress = 1
    this.phase = 'idle'
  }

  pending(): boolean { return this.phase === 'armed' || this.phase === 'animating' }
  ready(): boolean { return this.phase === 'idle' || this.phase === 'finished' }
  offset(): string { return `${(1 - this.progress) * 100}%` }

  cancel(): void {
    if (!this.pending()) return
    this.epoch += 1
    this.animationFinished = false
    this.progress = 1
    this.phase = 'cancelled'
    this.observe('cancelled')
  }

  transition(context: UIContext, onSettled: (success: boolean) => void): NavigationAnimatedTransition {
    const epoch = this.epoch
    return {
      timeout: 2500,
      transition: (proxy: NavigationTransitionProxy): void => {
        if (epoch !== this.epoch || this.phase !== 'armed') { proxy.finishTransition(); return }
        this.phase = 'animating'
        this.observe('animation_started')
        context.animateTo({ duration: 300, curve: Curve.FastOutSlowIn,
          onFinish: (): void => {
            if (epoch !== this.epoch || this.phase !== 'animating') return
            this.animationFinished = true
            this.observe('animation_finished')
            proxy.finishTransition()
          },
        }, (): void => { this.progress = 1 })
      },
      onTransitionEnd: (success: boolean): void => {
        if (epoch !== this.epoch || this.phase !== 'animating') return
        const complete = success && this.animationFinished
        this.progress = 1
        this.phase = complete ? 'finished' : 'cancelled'
        this.observe(complete ? 'native_finished' : 'native_failed')
        onSettled(complete)
      },
    }
  }

  private observe(event: string): void {
    console.info(`[ReaderRouteTransition] time=${Date.now()} epoch=${this.epoch} event=${event}`)
  }
}
