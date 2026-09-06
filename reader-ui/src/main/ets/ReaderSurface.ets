import { ReaderPagedSession, ReaderPagedSnapshot, ReaderUnitKey, ReaderFragment, ReaderDisplayPolicy } from '@reader-kit/core'
import { ReaderPagerSurface } from './ReaderPagerSurface'
import { ReaderContinuousSurface } from './ReaderContinuousSurface'
import { ReaderChrome } from './ReaderChrome'
import { ReaderPageStatus } from './ReaderPageStatus'
import { ReaderThumbnailRail } from './ReaderThumbnailRail'

/** Reading composition only. The host owns its route, window and persistence. */
@ComponentV2
export struct ReaderSurface {
  @Require @Param session: ReaderPagedSession
  @Require @Param initialUnit: ReaderUnitKey
  @Require @Param active: boolean
  @Param initialIndex: number = 0
  @Param topInset: number = 0
  @Param bottomInset: number = 0
  @Param accent: ResourceColor = '#D93646'
  @Event onClose: () => void = () => {}
  @Event onChromeVisible: (visible: boolean) => void = () => {}
  @Local private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  @Local private chromeVisible: boolean = true
  @Local private thumbnailsVisible: boolean = false
  @Local private previewIndex: number = -1

  aboutToAppear(): void {
    this.session.setNeighborPreload(true)
    this.session.setViewportActive(this.active)
    this.session.subscribe((state: ReaderPagedSnapshot): void => { this.state = state })
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  aboutToDisappear(): void { this.session.close() }

  @Monitor('active')
  onActiveChanged(): void {
    if (!this.active) this.previewIndex = -1
    this.session.setViewportActive(this.active)
  }

  private toggleChrome(): void {
    if (!this.active) return
    this.chromeVisible = !this.chromeVisible
    if (!this.chromeVisible) this.previewIndex = -1
    this.onChromeVisible(this.chromeVisible)
    console.info(`[ReaderSurface] chrome=${this.chromeVisible}`)
  }

  private pageTap(x: number): void {
    if (!this.active) return
    if (x >= 1 / 3 && x <= 2 / 3) this.toggleChrome()
    else {
      const previous = (x < 1 / 3) === (this.state.policy.direction === 'ltr')
      this.session.move(previous ? 'previous' : 'next')
    }
  }

  private retry(topology: number, key: string, slot: number, request: number): void {
    void this.session.retryItem(topology, key, slot, request)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.state.policy.layout === 'continuous') {
        ReaderContinuousSurface({
          snapshot: this.state, active: this.active,
          onTap: (): void => { this.toggleChrome() },
          onRange: (start: number, end: number, topology: number, navigation: number): void => {
            this.session.setContinuousRange(start, end, topology, navigation)
          },
          onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
            this.session.reportPresentation(slot, request, success, width, height)
          },
          onRetry: (topology: number, key: string, slot: number, request: number): void => {
            this.retry(topology, key, slot, request)
          },
          onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment): void => {
            this.session.reportCachedRenderFailure(topology, key, slot, request, fragment)
          },
          onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number): void => {
            this.session.reportContinuousVisible(topology, navigation, key, slot, request, x, y)
          },
        })
      } else {
        ReaderPagerSurface({
          snapshot: this.state, active: this.active,
          onTap: (x: number): void => { this.pageTap(x) },
          onSelect: (index: number, topology: number, navigation: number): void => {
            this.session.selectDisplay(index, topology, navigation)
          },
          onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
            this.session.reportPresentation(slot, request, success, width, height)
          },
          onRetry: (topology: number, key: string, slot: number, request: number): void => {
            this.retry(topology, key, slot, request)
          },
          onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment): void => {
            this.session.reportCachedRenderFailure(topology, key, slot, request, fragment)
          },
          onVisible: (selection: number, slot: number, request: number, fragment: ReaderFragment): void => {
            this.session.reportVisible(selection, slot, request, fragment)
          },
        })
      }
      if (this.state.error.length > 0) {
        Column({ space: 16 }) {
          Text($r('app.string.rkit_catalog_failed')).fontColor(Color.White).fontSize(16)
          Button($r('app.string.rkit_retry')).height(40).constraintSize({ minWidth: 120 })
            .backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { void this.session.retry() })
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(24)
      }
      if (this.chromeVisible) {
        if (this.thumbnailsVisible && this.active && this.state.phase === 'ready') {
          Column() {
            ReaderThumbnailRail({ session: this.session, snapshot: this.state, accent: this.accent,
              previewIndex: this.previewIndex,
              onSeek: (index: number, unit: ReaderUnitKey, navigation: number): void => {
                this.session.seekSource(index, unit, navigation)
              },
            })
          }.width('100%').height(156).padding({ top: 8, bottom: 8 })
            .margin({ bottom: this.bottomInset + 112 }).backgroundColor('#CC000000').clip(true)
        }
        ReaderChrome({ snapshot: this.state, active: this.active, topInset: this.topInset,
          bottomInset: this.bottomInset, accent: this.accent, onClose: this.onClose,
          thumbnailsVisible: this.thumbnailsVisible,
          onThumbnails: (): void => { this.thumbnailsVisible = !this.thumbnailsVisible },
          onPolicy: (policy: ReaderDisplayPolicy): void => { this.session.setPolicy(policy) },
          onPreview: (index: number, unit: ReaderUnitKey | null, navigation: number): void => {
            this.previewIndex = this.active && this.chromeVisible && unit !== null &&
              this.state.unit?.key.equals(unit) && this.state.navigationRevision === navigation ? index : -1
            console.info(`[ReaderSurface] preview_source=${this.previewIndex} reading_source=${this.state.anchor?.sourceIndexHint ?? -1}`)
          },
          onSeek: (index: number, unit: ReaderUnitKey, navigation: number): void => {
            const accepted = this.session.seekSource(index, unit, navigation)
            console.info(`[ReaderSurface] seek_source=${index} accepted=${accepted}`)
          },
        })
      } else if (this.state.unit !== null && this.state.unit.pageCount > 0) {
        ReaderPageStatus({ value: `${(this.state.anchor?.sourceIndexHint ?? 0) + 1} / ${this.state.unit.pageCount}`,
          bottomMargin: this.bottomInset + 8 })
      }
    }.width('100%').height('100%').backgroundColor(Color.Black).id('rkit-reading-surface')
  }
}
