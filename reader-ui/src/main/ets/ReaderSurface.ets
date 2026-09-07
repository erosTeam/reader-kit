import { ReaderPagedSession, ReaderPagedSnapshot, ReaderUnitKey, ReaderFragment, ReaderDisplayPolicy,
  ReaderInputPort, ReaderMoveIntent, ReaderImageShareHost, ReaderImageShareTarget,
  ReaderImageShareController, ReaderPagedFrame, ReaderImageInformation } from '@reader-kit/core'
import { ReaderPagerSurface } from './ReaderPagerSurface'
import { ReaderContinuousSurface } from './ReaderContinuousSurface'
import { ReaderChrome } from './ReaderChrome'
import { ReaderPageStatus } from './ReaderPageStatus'
import { ReaderThumbnailRail } from './ReaderThumbnailRail'
import { BusinessError } from '@kit.BasicServicesKit'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderEntryPreview, ReaderEntryPreviewSource } from './ReaderEntryPreview'

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
  @Param input: ReaderInputPort | null = null
  @Param imageShare: ReaderImageShareHost | null = null
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryPreview: ReaderEntryPreviewSource | null = null
  @Event onClose: () => void = () => {}
  @Event onChromeVisible: (visible: boolean) => void = () => {}
  @Local private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  @Local private chromeVisible: boolean = true
  @Local private thumbnailsVisible: boolean = false
  @Local private previewIndex: number = -1
  @Local private shareBusy: boolean = false
  @Local private informationBusy: boolean = false
  private informationEpoch: number = 0
  @Local private informationPresented: boolean = false
  private informationNavigation: number = -1
  private shareController: ReaderImageShareController = new ReaderImageShareController()
  private inputConnection: number = 0
  private inputLocked: boolean = true
  private inputTopology: number = -1
  private touching: boolean = false
  private menuVisible: boolean = false

  aboutToAppear(): void {
    this.session.setNeighborPreload(true)
    this.session.setViewportActive(this.active)
    this.shareController.subscribe((busy: boolean): void => { this.shareBusy = busy })
    this.session.subscribe((state: ReaderPagedSnapshot): void => {
      if (this.informationBusy && !this.informationPresented && state.navigationRevision !== this.informationNavigation) {
        this.informationEpoch += 1; this.informationBusy = false
      }
      this.state = state
      this.entryTransition?.update(state)
      this.shareController.update(ReaderImageShareTarget.from(state), this.active)
    })
    this.inputConnection = this.input?.connect((intent: ReaderMoveIntent): boolean => this.externalMove(intent)) ?? 0
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  aboutToDisappear(): void {
    this.entryTransition?.cancel()
    this.informationEpoch += 1
    this.shareController.close()
    this.input?.disconnect(this.inputConnection)
    this.session.close()
  }

  @Monitor('active')
  onActiveChanged(): void {
    if (!this.active) {
      this.entryTransition?.cancel()
      this.previewIndex = -1; this.touching = false
      if (!this.informationPresented) { this.informationEpoch += 1; this.informationBusy = false }
    }
    this.shareController.update(ReaderImageShareTarget.from(this.session.snapshot()), this.active)
    this.session.setViewportActive(this.active)
  }

  private async shareImage(): Promise<void> {
    const host = this.imageShare
    if (host === null || !this.active || this.previewIndex >= 0 || this.menuVisible || this.informationBusy) return
    this.shareController.update(ReaderImageShareTarget.from(this.session.snapshot()), this.active)
    const outcome = await this.shareController.share(host)
    if (outcome === 'failed' && this.active) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.rkit_share_failed') })
    }
  }

  private text(name: string): string {
    // This HAR is merged into the host. Main/test packages do not share numeric resource IDs.
    return this.getUIContext().getHostContext()?.resourceManager.getStringByNameSync(name) ?? ''
  }

  private informationText(value: ReaderImageInformation): string {
    const unknown = this.text('rkit_unknown')
    const format = value.mimeType.startsWith('image/') ? value.mimeType.substring(6).toUpperCase() : unknown
    const bytes = value.bytes > 0 ? (value.bytes < 1024 ? `${value.bytes} B` : value.bytes < 1048576 ?
      `${(value.bytes / 1024).toFixed(1)} KB` : `${(value.bytes / 1048576).toFixed(1)} MB`) : unknown
    let variant = unknown
    if (value.variant === 'source') variant = this.text('rkit_info_source')
    else if (value.variant === 'resampled') variant = this.text('rkit_info_resampled')
    else if (value.variant === 'original') variant = this.text('rkit_original')
    else if (value.variant === 'enhanced') variant = this.text('rkit_info_enhanced')
    else if (value.variant === 'translated') variant = this.text('rkit_info_translated')
    const lines: string[] = [
      `${this.text('rkit_info_format')}${format}`,
      `${this.text('rkit_info_size')}${bytes}`,
      `${this.text('rkit_info_current')}${variant}`,
    ]
    if (value.originalAvailable !== null) lines.push(this.text(value.originalAvailable ?
      'rkit_info_original_available' : 'rkit_info_original_unavailable'))
    lines.push(`${this.text('rkit_info_dimensions')}${value.width > 0 && value.height > 0 ?
      `${value.width} x ${value.height}` : unknown}`)
    return lines.join('\n')
  }

  private async showInformation(frame: ReaderPagedFrame): Promise<void> {
    const state = this.session.snapshot()
    const unit = state.unit?.key.copy() ?? null
    if (!this.active || this.informationBusy || this.shareBusy || this.previewIndex >= 0 || unit === null) return
    const epoch = ++this.informationEpoch
    console.info(`[ReaderSurface] information_request source=${frame.part.sourceIndex} slot=${frame.slotId} request=${frame.asset.assetRequestId}`)
    this.informationNavigation = state.navigationRevision
    this.informationBusy = true
    const value = await this.session.imageInformation(frame.slotId, frame.asset.assetRequestId, unit, state.navigationRevision)
    if (epoch !== this.informationEpoch) return
    if (!this.active || this.session.snapshot().navigationRevision !== state.navigationRevision) {
      this.informationBusy = false
      return
    }
    if (value === null) {
      console.warn('[ReaderSurface] information_unavailable')
      this.informationBusy = false
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.rkit_info_failed') })
      return
    }
    try {
      this.informationPresented = true
      console.info('[ReaderSurface] information_present')
      this.getUIContext().showAlertDialog({
        title: $r('app.string.rkit_info_title', frame.part.sourceIndex + 1),
        message: this.informationText(value),
        primaryButton: { value: $r('app.string.rkit_ok'), action: (): void => {} },
        onDidDisappear: (): void => {
          if (epoch === this.informationEpoch) { this.informationPresented = false; this.informationBusy = false }
        },
      })
    } catch (error) {
      console.warn(`[ReaderSurface] information_present_failed code=${(error as BusinessError).code ?? 0}`)
      this.informationPresented = false; this.informationBusy = false
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.rkit_info_failed') })
    }
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

  private externalMove(intent: ReaderMoveIntent): boolean {
    if (this.entryTransition?.phase === 'layout' || !this.active || this.state.phase !== 'ready' ||
      this.touching || this.menuVisible || this.shareBusy || this.informationBusy ||
      this.previewIndex >= 0 || this.inputTopology !== this.state.topologyRevision || this.inputLocked) return false
    const navigation = this.session.snapshot().navigationRevision
    this.session.move(intent)
    return this.session.snapshot().navigationRevision !== navigation
  }

  private reportInputLock(locked: boolean, topology: number): void {
    if (topology !== this.state.topologyRevision) return
    this.inputTopology = topology
    this.inputLocked = locked
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // The existing cell feedback stays above the optional source preview.
      // Real image opacity still controls its later handoff to the same content.
      if (this.entryTransition !== null && this.entryPreview !== null) {
        ReaderEntryPreview({ entry: this.entryTransition, source: this.entryPreview })
      }
      // This content owns a black canvas even when its host (or the separate Lab) is light.
      WithTheme({ colorMode: ThemeColorMode.DARK }) {
        if (this.state.policy.layout === 'continuous') {
          ReaderContinuousSurface({
            snapshot: this.state, active: this.active,
            onInputLockChange: (locked: boolean, topology: number): void => { this.reportInputLock(locked, topology) },
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
            entryTransition: this.entryTransition,
            onInputLockChange: (locked: boolean, topology: number): void => { this.reportInputLock(locked, topology) },
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
          shareAvailable: this.imageShare !== null, shareBusy: this.shareBusy,
          informationBusy: this.informationBusy,
          informationPreparing: this.informationBusy && !this.informationPresented,
          informationAvailable: this.session.informationSupported(),
          onInformation: (frame: ReaderPagedFrame): void => { void this.showInformation(frame) },
          onShare: (): void => { void this.shareImage() },
          onMenuVisible: (visible: boolean): void => { this.menuVisible = visible },
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
      .onTouch((event: TouchEvent): void => {
        this.touching = event.type !== TouchType.Up && event.type !== TouchType.Cancel
      })
  }
}
