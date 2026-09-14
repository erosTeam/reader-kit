import { ReaderPagedSession, ReaderPagedSnapshot, ReaderPagedFrame, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderPagerSurface } from './ReaderPagerSurface'
import { ReaderContinuousSurface } from './ReaderContinuousSurface'

class ReaderLabHeldMetrics {
  slot: number
  request: number
  width: number
  height: number
  constructor(slot: number, request: number, width: number, height: number) {
    this.slot = slot
    this.request = request
    this.width = width
    this.height = height
  }
}

/** Diagnostic controls only; the viewport has no dependency on this chrome. */
@ComponentV2
export struct ReaderLabSurface {
  @Require @Param session: ReaderPagedSession
  @Require @Param initialUnit: ReaderUnitKey
  @Require @Param active: boolean
  @Param initialIndex: number = 0
  @Param preloadDepth: number = 0
  /** Explicit debug Want only; inject one render failure, never a network fault or cache mutation. */
  @Param failurePage: number = -1
  @Param failureLayout: string = 'continuous'
  @Param delayedMetricsPage: number = -1
  @Local private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  @Local private heldMetrics: ReaderLabHeldMetrics | null = null
  @Local private metricsReleased: boolean = false
  private failureInjected: boolean = false
  private failureTimer: number = 0

  aboutToAppear(): void {
    this.session.setNeighborPreload(true)
    this.session.setPreloadDepth(this.preloadDepth)
    this.session.setViewportActive(this.active)
    this.session.subscribe((state: ReaderPagedSnapshot): void => { this.state = state })
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  @Monitor('preloadDepth')
  onPreloadDepthChanged(): void { this.session.setPreloadDepth(this.preloadDepth) }

  aboutToDisappear(): void {
    if (this.failureTimer !== 0) clearTimeout(this.failureTimer)
    this.session.close()
  }

  @Monitor('active')
  onActiveChanged(): void {
    this.session.setViewportActive(this.active)
    console.info(`[ReaderLab] viewport_active=${this.active}`)
  }

  private error(): string {
    return this.state.error
  }

  private presented(slot: number, request: number, success: boolean, width: number, height: number): void {
    if (success && !this.metricsReleased && this.delayedMetricsPage >= 0 && width > 0 && height > 0 &&
      this.state.window.some((item) => item.frames.some((frame: ReaderPagedFrame) =>
        frame.slotId === slot && frame.asset.assetRequestId === request && frame.asset.kind === 'original' &&
        frame.part.sourceIndex === this.delayedMetricsPage))) {
      this.heldMetrics = new ReaderLabHeldMetrics(slot, request, width, height)
      console.info(`[ReaderLab] held_metrics page=${this.delayedMetricsPage + 1} slot=${slot} request=${request} width=${width} height=${height}`)
      width = 0
      height = 0
    }
    this.session.reportPresentation(slot, request, success, width, height)
    if (!success || this.failureInjected || this.failurePage < 0 || this.state.policy.layout !== this.failureLayout) return
    const state = this.session.snapshot()
    const item = state.window.find((value) => value.frames.some((frame: ReaderPagedFrame) =>
      frame.slotId === slot && frame.asset.assetRequestId === request &&
      frame.part.sourceIndex === this.failurePage && frame.asset.phase === 'displayed'))
    if (item === undefined) return
    const fragment = item.frames.find((frame: ReaderPagedFrame) =>
      frame.slotId === slot && frame.asset.assetRequestId === request)!.part.fragment
    this.failureInjected = true
    this.failureTimer = setTimeout((): void => {
      this.failureTimer = 0
      this.session.reportCachedRenderFailure(state.topologyRevision, item.key, slot, request, fragment)
      console.info(`[ReaderLab] injected_render_failure page=${this.failurePage + 1} slot=${slot} request=${request} fragment=${fragment}`)
    }, 0)
  }

  private releaseMetrics(): void {
    const held = this.heldMetrics
    if (held === null || this.metricsReleased || !this.active || this.state.phase !== 'ready') return
    this.metricsReleased = true
    this.session.reportPresentation(held.slot, held.request, true, held.width, held.height)
    console.info(`[ReaderLab] released_metrics page=${this.delayedMetricsPage + 1} slot=${held.slot} request=${held.request} width=${held.width} height=${held.height}`)
  }

  private toggleAlignment(): void {
    const policy = this.state.policy.copy()
    if (policy.layout === 'single') {
      policy.splitWidePages = !policy.splitWidePages
      if (policy.splitWidePages) policy.rotateWidePages = false
    }
    else policy.firstPageAlone = !policy.firstPageAlone
    this.session.setPolicy(policy)
  }

  private alignmentLabel(): ResourceStr {
    if (this.state.policy.layout === 'single') {
      return this.state.policy.splitWidePages ? $r('app.string.rkit_split_on') : $r('app.string.rkit_split_off')
    }
    return this.state.policy.firstPageAlone ? $r('app.string.rkit_cover_on') : $r('app.string.rkit_cover_off')
  }

  private layoutLabel(): ResourceStr {
    if (this.state.policy.layout === 'continuous') return $r('app.string.rkit_continuous')
    return this.state.policy.layout === 'single' ? $r('app.string.rkit_single') : $r('app.string.rkit_spread')
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.rkit_lab_scope')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      Text(this.state.unit === null ? '' : this.state.unit.title)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 12 }) {
        Text(this.state.unit === null ? '0 / 0' : `${(this.state.anchor?.sourceIndexHint ?? 0) + 1} / ${this.state.unit.pageCount}`)
          .id('rkit-page-position')
        Text(this.state.displayCount === 0 ? '0 / 0' :
          `${this.state.displayIndex + 1} / ${this.state.displayCount} · ${this.state.anchor?.fragment ?? 'whole'}`)
          .fontSize(12).id('rkit-display-position')
        Text(this.state.phase).fontSize(12).id('rkit-phase')
      }
      Row({ space: 12 }) {
        Select([{ value: $r('app.string.rkit_single') }, { value: $r('app.string.rkit_spread') },
          { value: $r('app.string.rkit_continuous') }])
          .selected(this.state.policy.layout === 'single' ? 0 : this.state.policy.layout === 'spread' ? 1 : 2)
          .value(this.layoutLabel())
          .font({ size: 14 }).height(40).layoutWeight(1).id('rkit-layout')
          .onSelect((index: number): void => {
            const policy = this.state.policy.copy()
            policy.layout = index === 0 ? 'single' : index === 1 ? 'spread' : 'continuous'
            this.session.setPolicy(policy)
          })
        Select([{ value: $r('app.string.rkit_ltr') }, { value: $r('app.string.rkit_rtl') }])
          .selected(this.state.policy.direction === 'ltr' ? 0 : 1)
          .value(this.state.policy.direction === 'ltr' ? $r('app.string.rkit_ltr') : $r('app.string.rkit_rtl'))
          .font({ size: 14 }).height(40).layoutWeight(1).id('rkit-direction')
          .enabled(this.state.policy.layout !== 'continuous')
          .onSelect((index: number): void => {
            const policy = this.state.policy.copy()
            policy.direction = index === 0 ? 'ltr' : 'rtl'
            this.session.setPolicy(policy)
          })
        Button(this.alignmentLabel()).fontSize(14).height(40).layoutWeight(1)
          .enabled(this.state.policy.layout !== 'continuous')
          .id('rkit-alignment').onClick((): void => { this.toggleAlignment() })
      }
      .width('100%')
      if (this.state.policy.layout === 'continuous') {
        ReaderContinuousSurface({
          snapshot: this.state, active: this.active,
          onRange: (start: number, end: number, topology: number, navigation: number): void => {
            this.session.setContinuousRange(start, end, topology, navigation)
          },
          onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
            this.presented(slot, request, success, width, height)
          },
          onRetry: (topology: number, key: string, slot: number, request: number): void => {
            void this.session.retryItem(topology, key, slot, request).then((accepted: boolean): void => {
              console.info(`[ReaderLab] item_retry key=${key} slot=${slot} request=${request} accepted=${accepted}`)
            })
          },
          onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment): void => {
            this.session.reportCachedRenderFailure(topology, key, slot, request, fragment)
          },
          onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number): void => {
            const accepted = this.session.reportContinuousVisible(topology, navigation, key, slot, request, x, y)
            if (accepted) console.info(`[ReaderLab] continuous_observation key=${key} slot=${slot} request=${request} y=${y.toFixed(5)}`)
          },
        }).layoutWeight(1)
      } else {
        ReaderPagerSurface({
          snapshot: this.state, active: this.active,
          onRetry: (topology: number, key: string, slot: number, request: number): void => {
            void this.session.retryItem(topology, key, slot, request).then((accepted: boolean): void => {
              console.info(`[ReaderLab] item_retry key=${key} slot=${slot} request=${request} accepted=${accepted}`)
            })
          },
          onSelect: (index: number, topologyRevision: number, navigationRevision: number): void => {
            const accepted = this.session.selectDisplay(index, topologyRevision, navigationRevision)
            console.info(`[ReaderLab] pager_selection index=${index} accepted=${accepted}`)
          },
          onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number): void => {
            this.presented(slotId, requestId, success, width, height)
          },
          onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.session.reportCachedRenderFailure(topologyRevision, itemKey, slotId, requestId, fragment)
          },
          onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.session.setViewportActive(this.active)
            const accepted = this.session.reportVisible(selectionId, slotId, requestId, fragment)
            const snapshot = this.session.snapshot()
            console.info(`[ReaderLab] original_observation active=${this.active} selection=${selectionId} slot=${slotId} request=${requestId} accepted=${accepted} sourceIndex=${snapshot.observedAnchor?.sourceIndexHint ?? -1} fragment=${snapshot.observedAnchor?.fragment ?? 'whole'}`)
          },
        }).layoutWeight(1)
      }
      if (this.error().length > 0) {
        Text(this.error()).fontSize(12).id('rkit-error')
        Button($r('app.string.rkit_retry'))
          .height(40).constraintSize({ minWidth: 120 })
          .onClick((): void => { void this.session.retry() })
      }
      Row({ space: 12 }) {
        Button($r('app.string.rkit_previous_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.displayIndex > 0)
          .id('rkit-previous-page')
          .onClick((): void => { this.session.move('previous') })
        Button($r('app.string.rkit_next_page'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.displayIndex + 1 < this.state.displayCount)
          .id('rkit-next-page')
          .onClick((): void => { this.session.move('next') })
      }
      Row({ space: 12 }) {
        Button(this.state.kind === 'original' ? $r('app.string.rkit_thumbnail') : $r('app.string.rkit_original'))
          .layoutWeight(1).height(40)
          .enabled(this.state.phase === 'ready' && this.state.frames.length > 0 &&
            this.state.frames.every((frame: ReaderPagedFrame) => frame.asset.page !== null && frame.asset.page.thumbnail.available))
          .id('rkit-asset-kind')
          .onClick((): void => {
            this.session.setAssetKind(this.state.kind === 'original' ? 'thumbnail' : 'original')
          })
        if (this.state.canPreviousUnit) {
          Button($r('app.string.rkit_previous_unit')).height(40).id('rkit-previous-unit')
            .onClick((): void => { void this.session.switchUnit('previous') })
        }
        if (this.state.canNextUnit) {
          Button($r('app.string.rkit_next_unit')).height(40).id('rkit-next-unit')
            .onClick((): void => { void this.session.switchUnit('next') })
        }
      }
      if (this.delayedMetricsPage >= 0) {
        Button($r('app.string.rkit_release_metrics')).height(40).constraintSize({ minWidth: 120 })
          .enabled(this.active && this.state.phase === 'ready' && this.heldMetrics !== null && !this.metricsReleased)
          .id('rkit-release-metrics').onClick((): void => { this.releaseMetrics() })
      }
      Text(`D3 · cancellation=${this.session.cancellationMode()}` +
        (this.failurePage >= 0 ? ` · failure-probe=P${this.failurePage + 1}/${this.failureLayout}` : '') +
        (this.delayedMetricsPage >= 0 ? ` · delay-metrics=P${this.delayedMetricsPage + 1}` : ''))
        .fontSize(11).fontColor($r('sys.color.font_secondary'))
    }
    .padding(12).width('100%').height('100%')
    .backgroundColor($r('sys.color.background_primary'))
  }
}
