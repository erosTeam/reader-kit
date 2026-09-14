import { ReaderPagedSession, ReaderPagedSnapshot, ReaderUnitKey, ReaderFragment, ReaderDisplayPolicy, ReaderLayout,
  ReaderReadingAnchor, ReaderObservedPosition, ReaderProcessedAssetVariant, ReaderVariantPreference,
  ReaderInputPort, ReaderMoveIntent, ReaderImageShareHost, ReaderImageShareTarget,
  ReaderImageShareController, ReaderPagedFrame, ReaderImageInformation,
  ReaderImageSaveHost, ReaderImageSaveController, ReaderImageSaveChoice, ReaderAutoReadController } from '@reader-kit/core'
import { ReaderPagerCommand, ReaderPagerSurface } from './ReaderPagerSurface'
import { ReaderContinuousSurface } from './ReaderContinuousSurface'
import { ReaderChrome, ReaderRuntimePolicyIntent } from './ReaderChrome'
import { ReaderPageStatus } from './ReaderPageStatus'
import { ReaderThumbnailRail } from './ReaderThumbnailRail'
import { BusinessError } from '@kit.BasicServicesKit'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderEntryPreview, ReaderEntryPreviewSource } from './ReaderEntryPreview'
import { ReaderTapAction } from './ReaderTapAction'
import { ReaderTapZonePreviewRegion } from './ReaderTapZonePreviewRegion'
import { ReaderHostAction } from './ReaderHostAction'
import { ReaderZoomResetCommand } from './ReaderZoomResetCommand'
import { ReaderCloseContext } from './ReaderCloseContext'
import { readerElementKey } from './ReaderElementKey'

/** Reading composition only. The host owns its route, window and persistence. */
@ComponentV2
export struct ReaderSurface {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param canvasBackground: ResourceColor = Color.Black
  @Param canvasForeground: ResourceColor = Color.White
  @Require @Param session: ReaderPagedSession
  @Require @Param initialUnit: ReaderUnitKey
  @Require @Param active: boolean
  @Param closing: boolean = false
  @Param showPageNumber: boolean = true
  @Param tapZoneResolver: ((xFraction: number, yFraction: number, layout: ReaderLayout) => ReaderTapAction) | null = null
  /** Host-owned normalized geometry; revision explicitly requests one-shot shared presentation. */
  @Param tapZonePreviewRegions: ReaderTapZonePreviewRegion[] = []
  @Param tapZonePreviewRevision: number = 0
  @Param beforeShowChrome: ((isCurrent: () => boolean) => Promise<boolean>) | null = null
  @Param initialIndex: number = 0
  @Param topInset: number = 0
  @Param bottomInset: number = 0
  @Param accent: ResourceColor = '#D93646'
  @Param input: ReaderInputPort | null = null
  @Param imageShare: ReaderImageShareHost | null = null
  @Param imageSave: ReaderImageSaveHost | null = null
  /** Host-owned, read-only information lines appended after retained file facts. */
  @Param informationSupplement: ((frame: ReaderPagedFrame, value: ReaderImageInformation) => string[]) | null = null
  @Param autoReadAvailable: boolean = false
  @Param autoReadSeconds: number = 3
  @Param pageTurnAnimation: boolean = false
  /** Host-owned visual spacing between continuous pages and separated spread slots. */
  @Param pageGap: number = 0
  /** Host preference for future cache warming; native render neighbors remain fixed and bounded. */
  @Param preloadDepth: number = 0
  /** Optional host policy. reader-kit only requests exact host-prepared derivatives. */
  @Param preferredVariant: ReaderProcessedAssetVariant | 'default' = 'default'
  @Param preferredVariantIdentity: string = ''
  /** Optional per-source host policy. Bump revision whenever its result can change. */
  @Param variantPreferenceResolver: ((sourceIndex: number) => ReaderVariantPreference) | null = null
  @Param variantPreferenceRevision: number = 0
  @Event onVariantSelection: (sourceIndex: number, preference: ReaderVariantPreference,
    result: 'changed' | 'unchanged' | 'unavailable' | 'stale') => void = () => {}
  @Param cropBorders: boolean = false
  @Param cropAvailable: boolean = false
  @Param hostSettingsAvailable: boolean = false
  @Event onHostSettings: () => void = () => {}
  @Param externalOpenAvailable: boolean = false
  @Event onExternalOpen: (source: ReaderUnitKey) => void = () => {}
  @Param hostActions: ReaderHostAction[] = []
  @Event onHostAction: (id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number) => void = () => {}
  @Param hostCenterActionAvailable: boolean = false
  @Param hostCenterActionLabel: ResourceStr = ''
  @Event onHostCenterAction: (source: ReaderUnitKey, navigation: number) => void = () => {}
  /** Passive host feedback; it never changes layout or handles input. */
  @Param hostStatusVisible: boolean = false
  @Param hostStatusText: string = ''
  @Param hostStatusBusy: boolean = false
  @Param chapterNavigationAvailable: boolean = false
  @Param chapterNavigationBusy: boolean = false
  @Event onChapter: (direction: 'previous' | 'next', source: ReaderUnitKey) => void = () => {}
  /** Native-visible original position only. The host decides whether and how to persist it. */
  @Event onObserved: (anchor: ReaderReadingAnchor) => void = () => {}
  /** Decoded visible coverage for host-owned completion and progress persistence. */
  @Event onObservedPosition: (position: ReaderObservedPosition) => void = () => {}
  /** Adopted runtime display policy only. The host decides whether and how to persist it. */
  @Event onPolicyChanged: (policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent) => void = () => {}
  /** Adopted runtime border-crop state only. The host owns its preference model. */
  @Event onCropChanged: (enabled: boolean, policy: ReaderDisplayPolicy) => void = () => {}
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryPreview: ReaderEntryPreviewSource | null = null
  @Event onClose: (context: ReaderCloseContext | null) => void = () => {}
  @Event onChromeVisible: (visible: boolean) => void = () => {}
  /** Host-neutral foreground interaction signal for pausable processors. */
  @Event onInteractionBusy: (busy: boolean) => void = () => {}
  @Local private state: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  @Local private chromeVisible: boolean = true
  @Local private thumbnailsVisible: boolean = false
  @Local private previewIndex: number = -1
  @Local private tapZonePreviewVisible: boolean = false
  @Local private shareBusy: boolean = false
  @Local private saveBusy: boolean = false
  @Local private autoReadEnabled: boolean = false
  @Local private pagerCommand: ReaderPagerCommand | null = null
  @Local private zoomResetCommand: ReaderZoomResetCommand | null = null
  @Local private zoomed: boolean = false
  private pagerCommandSerial: number = 0
  private zoomResetSerial: number = 0
  private autoReadController: ReaderAutoReadController = new ReaderAutoReadController((): boolean => {
    return this.externalMove('next')
  })
  private saveController: ReaderImageSaveController = new ReaderImageSaveController()
  private saveFeedback: ResourceStr | null = null
  @Local private informationBusy: boolean = false
  private informationEpoch: number = 0
  private originalFeedbackEpoch: number = 0
  @Local private informationPresented: boolean = false
  private informationNavigation: number = -1
  private shareController: ReaderImageShareController = new ReaderImageShareController()
  private inputConnection: number = 0
  private inputLocked: boolean = true
  private inputTopology: number = -1
  private touching: boolean = false
  private menuVisible: boolean = false
  private chromeEpoch: number = 0
  private chromeShowPending: boolean = false
  private chromeDisposed: boolean = false
  private chromeCloseRequested: boolean = false
  private lastObservedSignature: string = ''
  private lastObservedPositionSignature: string = ''
  private variantAttemptContext: string = ''
  private variantAttempts: Set<string> = new Set<string>()
  private interactionBusyReported: boolean = false
  private tapZonePreviewShownRevision: number = 0

  private reportZoomed(zoomed: boolean, topology: number, navigation: number): void {
    if (!this.active || this.closing || this.chromeDisposed || topology !== this.state.topologyRevision ||
      navigation !== this.state.navigationRevision) return
    this.zoomed = zoomed
  }

  private resetZoom(source: ReaderUnitKey, navigation: number): void {
    if (!this.active || this.closing || this.chromeDisposed || !this.zoomed || this.state.phase !== 'ready' ||
      this.state.unit?.key.equals(source) !== true || this.state.navigationRevision !== navigation) return
    this.zoomResetSerial += 1
    this.zoomResetCommand = new ReaderZoomResetCommand(this.zoomResetSerial,
      this.state.topologyRevision, this.state.navigationRevision)
  }

  private syncPreferredVariant(state: ReaderPagedSnapshot): void {
    const unit = state.unit?.key
    const context = JSON.stringify([unit?.scope ?? '', unit?.work ?? '', unit?.unit ?? '', state.navigationRevision,
      this.preferredVariant, this.preferredVariantIdentity, this.variantPreferenceRevision])
    if (context !== this.variantAttemptContext) {
      this.variantAttemptContext = context
      this.variantAttempts.clear()
    }
    if (!this.active || this.closing || this.chromeDisposed || state.phase !== 'ready' ||
      state.kind !== 'original' || unit === undefined) return
    state.frames.forEach((frame: ReaderPagedFrame): void => {
      if (frame.asset.phase !== 'displayed') return
      const preference = this.variantPreferenceResolver?.(frame.part.sourceIndex) ??
        new ReaderVariantPreference(this.preferredVariant, this.preferredVariantIdentity)
      if (preference.variant !== 'default' && preference.identity.length === 0) return
      const wantsDefault = preference.variant === 'default'
      if (wantsDefault && frame.asset.variant !== 'enhanced' &&
        !(this.variantPreferenceResolver !== null && frame.asset.variant === 'translated')) return
      if (!wantsDefault && (frame.asset.variant === 'original' ||
        (this.variantPreferenceResolver === null && frame.asset.variant === 'translated') ||
        (frame.asset.variant === preference.variant && frame.asset.variantIdentity === preference.identity))) return
      const attempt = JSON.stringify([frame.part.sourceIndex, frame.slotId, frame.asset.requestId,
        preference.variant, preference.identity])
      if (this.variantAttempts.has(attempt)) return
      this.variantAttempts.add(attempt)
      void this.session.selectVariant(frame.slotId, frame.asset.requestId, unit.copy(), state.navigationRevision,
        preference.variant, preference.identity).then(result => {
          this.onVariantSelection(frame.part.sourceIndex,
            new ReaderVariantPreference(preference.variant, preference.identity), result)
        })
    })
  }

  private reportInteractionBusy(): void {
    const busy = this.active && !this.closing && !this.chromeDisposed &&
      (this.touching || this.menuVisible || this.tapZonePreviewVisible || this.inputLocked ||
        this.entryTransition?.pending() === true)
    if (busy === this.interactionBusyReported) return
    this.interactionBusyReported = busy
    this.onInteractionBusy?.(busy)
  }

  private publishObserved(state: ReaderPagedSnapshot): void {
    const anchor = state.observedAnchor
    if (!this.active || state.phase !== 'ready' || anchor === null ||
      state.observedSelectionId !== state.selectionId || state.unit?.key.equals(anchor.unit) !== true) return
    const signature = JSON.stringify([anchor.unit.scope, anchor.unit.work, anchor.unit.unit, anchor.pageKey,
      anchor.sourceIndexHint, anchor.fragment, anchor.x, anchor.y, state.observedSelectionId])
    if (signature !== this.lastObservedSignature) {
      this.lastObservedSignature = signature
      this.onObserved(anchor.copy())
    }
    const position = state.observedPosition()
    if (position === null) return
    const positionSignature = JSON.stringify([signature, position.displayedSourceIndexes,
      position.terminalSourceDisplayed])
    if (positionSignature === this.lastObservedPositionSignature) return
    this.lastObservedPositionSignature = positionSignature
    this.onObservedPosition(position.copy())
  }

  aboutToAppear(): void {
    this.chromeDisposed = false
    this.chromeCloseRequested = false
    this.session.setNeighborPreload(true)
    this.session.setPreloadDepth(this.preloadDepth)
    this.session.setCropEnabled(this.cropBorders)
    this.session.setViewportActive(this.active)
    this.autoReadController.subscribe((enabled: boolean): void => { this.autoReadEnabled = enabled })
    this.shareController.subscribe((busy: boolean): void => { this.shareBusy = busy; this.syncAutoRead() })
    this.saveController.subscribe((busy: boolean): void => { this.saveBusy = busy; this.syncAutoRead() })
    this.session.subscribe((state: ReaderPagedSnapshot): void => {
      if (state.topologyRevision !== this.state.topologyRevision || state.navigationRevision !== this.state.navigationRevision ||
        state.displayIndex !== this.state.displayIndex) this.zoomed = false
      if (state.navigationRevision !== this.state.navigationRevision || state.displayIndex !== this.state.displayIndex ||
        state.unit?.key.equals(this.state.unit?.key ?? this.initialUnit) !== true) this.originalFeedbackEpoch += 1
      if (this.informationBusy && !this.informationPresented && state.navigationRevision !== this.informationNavigation) {
        this.informationEpoch += 1; this.informationBusy = false
      }
      this.state = state
      this.publishObserved(state)
      this.syncPreferredVariant(state)
      this.entryTransition?.update(state)
      this.shareController.update(ReaderImageShareTarget.from(state), this.active)
      this.saveController.update(state, this.active)
      this.syncAutoRead()
    })
    this.inputConnection = this.input?.connect((intent: ReaderMoveIntent): boolean => this.externalMove(intent)) ?? 0
    void this.session.open(this.initialUnit, this.initialIndex)
  }

  @Monitor('preloadDepth')
  onPreloadDepthChanged(): void { this.session.setPreloadDepth(this.preloadDepth) }

  aboutToDisappear(): void {
    this.chromeDisposed = true
    this.autoReadController.close()
    this.invalidateChromeShow()
    this.entryTransition?.cancel()
    this.informationEpoch += 1
    this.shareController.close()
    this.saveController.close()
    this.saveFeedback = null
    this.input?.disconnect(this.inputConnection)
    if (this.interactionBusyReported) {
      this.interactionBusyReported = false
      this.onInteractionBusy(false)
    }
    this.session.close()
  }

  @Monitor('active')
  onActiveChanged(): void {
    if (!this.active) {
      this.originalFeedbackEpoch += 1
      this.invalidateChromeShow()
      this.entryTransition?.cancel()
      this.previewIndex = -1; this.tapZonePreviewVisible = false; this.touching = false
      if (!this.informationPresented) { this.informationEpoch += 1; this.informationBusy = false }
      this.variantAttemptContext = ''
      this.variantAttempts?.clear()
      this.zoomed = false
    }
    this.shareController.update(ReaderImageShareTarget.from(this.session.snapshot()), this.active)
    this.saveController.update(this.session.snapshot(), this.active)
    this.flushSaveFeedback()
    this.session.setViewportActive(this.active)
    this.reportInteractionBusy?.()
    this.syncPreferredVariant(this.session.snapshot())
    this.syncAutoRead()
  }

  @Monitor('preferredVariant', 'preferredVariantIdentity', 'variantPreferenceRevision')
  onPreferredVariantChanged(): void {
    this.variantAttemptContext = ''
    this.variantAttempts?.clear()
    this.syncPreferredVariant(this.session.snapshot())
  }

  @Monitor('autoReadAvailable', 'autoReadSeconds', 'shareBusy', 'saveBusy', 'informationBusy', 'previewIndex')
  onAutoReadInputsChanged(): void { this.syncAutoRead() }

  @Monitor('tapZonePreviewRevision', 'tapZonePreviewRegions')
  onTapZonePreviewChanged(): void {
    if (this.tapZonePreviewRevision <= this.tapZonePreviewShownRevision || this.closing ||
      this.chromeDisposed || this.state.phase !== 'ready' || this.validTapZonePreviewRegions().length === 0) return
    this.tapZonePreviewShownRevision = this.tapZonePreviewRevision
    this.tapZonePreviewVisible = true
    this.commitChromeVisible(false)
    this.reportInteractionBusy()
    this.syncAutoRead()
  }

  @Computed
  private get autoReadEntryBlocked(): boolean { return this.entryTransition?.phase === 'layout' }

  @Monitor('autoReadEntryBlocked')
  onAutoReadEntryChanged(): void { this.syncAutoRead() }

  private syncAutoRead(): void {
    if (!this.autoReadAvailable || this.closing || this.chromeCloseRequested || this.chromeDisposed) {
      this.autoReadController.stop()
      return
    }
    this.autoReadController.update(this.state, this.active,
      this.touching || this.menuVisible || this.tapZonePreviewVisible || this.shareBusy || this.saveBusy ||
      this.informationBusy || this.state.originalPreparing ||
      this.previewIndex >= 0 || this.inputTopology !== this.state.topologyRevision || this.inputLocked ||
      this.entryTransition?.phase === 'layout', this.autoReadSeconds)
  }

  private toggleAutoRead(): void {
    if (!this.autoReadAvailable || !this.active || this.closing || this.chromeCloseRequested) return
    this.syncAutoRead()
    this.autoReadController.setEnabled(!this.autoReadController.isEnabled())
  }

  private applyPolicy(policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent): void {
    if (!this.active || this.closing || this.state.phase !== 'ready') return
    this.session.setPolicy(policy)
    this.onPolicyChanged(this.session.snapshot().policy.copy(), intent)
  }

  private toggleCrop(): void {
    if (!this.cropAvailable || !this.active || this.closing || this.state.phase !== 'ready') return
    const policy = this.state.policy.copy()
    this.session.setCropEnabled(!this.state.cropEnabled)
    this.onCropChanged(this.session.snapshot().cropEnabled, policy)
  }

  private flushSaveFeedback(): void {
    if (!this.active || this.chromeDisposed || this.closing || this.chromeCloseRequested || this.saveFeedback === null) return
    this.getUIContext().getPromptAction().showToast({ message: this.saveFeedback })
    this.saveFeedback = null
  }

  private async saveImage(choice: ReaderImageSaveChoice): Promise<void> {
    const host = this.imageSave
    if (host === null || !this.active || this.closing || this.chromeCloseRequested ||
      this.shareBusy || this.informationBusy || this.session.snapshot().originalPreparing || this.previewIndex >= 0) return
    this.saveController.update(this.session.snapshot(), this.active)
    const result = await this.saveController.save(host, choice)
    if (this.chromeDisposed) return
    if (result.outcome === 'failed') this.saveFeedback = $r('app.string.rkit_save_failed')
    else if (result.outcome === 'completed') {
      const saved = result.items.filter(item => item.status === 'saved').length
      const failed = result.items.filter(item => item.status === 'failed').length
      if (saved > 0) this.saveFeedback = saved === result.items.length ? $r('app.string.rkit_save_success') :
        $r('app.string.rkit_save_partial', saved, result.items.length)
      else if (failed > 0 || result.items.length === 0) this.saveFeedback = $r('app.string.rkit_save_failed')
    }
    this.flushSaveFeedback()
  }

  private async shareImage(): Promise<void> {
    const host = this.imageShare
    if (host === null || !this.active || this.previewIndex >= 0 || this.menuVisible || this.informationBusy || this.saveBusy ||
      this.session.snapshot().originalPreparing) return
    this.shareController.update(ReaderImageShareTarget.from(this.session.snapshot()), this.active)
    const outcome = await this.shareController.share(host)
    if (outcome === 'failed' && this.active) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.rkit_share_failed') })
    }
  }

  private async selectOriginal(frames: ReaderPagedFrame[], unit: ReaderUnitKey, navigation: number, enabled: boolean): Promise<void> {
    if (!this.active || this.closing || this.chromeCloseRequested || this.chromeDisposed || this.saveBusy || this.shareBusy ||
      this.informationBusy || this.previewIndex >= 0 || this.session.snapshot().originalPreparing) return
    const epoch = this.originalFeedbackEpoch
    const displayIndex = this.session.snapshot().displayIndex
    const results = await Promise.all(frames.map(frame =>
      this.session.selectOriginal(frame.slotId, frame.asset.requestId, unit, navigation, enabled)))
    const current = this.session.snapshot()
    if (!this.active || this.closing || this.chromeCloseRequested || this.chromeDisposed || epoch !== this.originalFeedbackEpoch ||
      current.unit?.key.equals(unit) !== true || current.navigationRevision !== navigation || current.displayIndex !== displayIndex ||
      results.some(result => result === 'stale')) return
    const failed = frames.filter((_frame, index) => results[index] === 'unavailable')
    if (failed.length > 0) this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.rkit_original_failed', failed.map(frame => `${frame.part.sourceIndex + 1}`).join(', ')),
    })
  }

  private text(name: string): string {
    // This HAR is merged into the host. Main/test packages do not share numeric resource IDs.
    return this.getUIContext().getHostContext()?.resourceManager.getStringByNameSync(name) ?? ''
  }

  private informationText(value: ReaderImageInformation, frame: ReaderPagedFrame): string {
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
    const supplemental = this.informationSupplement?.(frame, value) ?? []
    lines.push(...supplemental.filter((line: string): boolean => line.trim().length > 0))
    return lines.join('\n')
  }

  private enhancementSourceIndex(): number {
    return this.state.anchor?.sourceIndexHint ?? -1
  }

  private enhancementVisible(): boolean {
    return this.preferredVariant === 'enhanced' && this.preferredVariantIdentity.length > 0
  }

  private enhancementProcessing(): boolean {
    const sourceIndex = this.enhancementSourceIndex()
    return sourceIndex >= 0 && this.state.isPreparingVariant(sourceIndex, 'enhanced')
  }

  private enhancementApplied(): boolean {
    const sourceIndex = this.enhancementSourceIndex()
    return sourceIndex >= 0 && this.state.frames.some((frame: ReaderPagedFrame): boolean =>
      frame.part.sourceIndex === sourceIndex && frame.asset.variant === 'enhanced')
  }

  private async showInformation(frame: ReaderPagedFrame): Promise<void> {
    const state = this.session.snapshot()
    const unit = state.unit?.key.copy() ?? null
    if (!this.active || this.informationBusy || this.shareBusy || this.saveBusy || this.session.snapshot().originalPreparing ||
      this.previewIndex >= 0 || unit === null) return
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
        message: this.informationText(value, frame),
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

  private invalidateChromeShow(): void {
    this.chromeEpoch += 1
    this.chromeShowPending = false
  }

  @Monitor('closing')
  onClosingChanged(): void {
    if (this.closing) {
      this.originalFeedbackEpoch += 1
      this.session.cancelOriginalPreparations()
      this.autoReadController.stop()
      this.saveController.close()
      this.invalidateChromeShow()
      this.variantAttemptContext = ''
      this.variantAttempts?.clear()
    }
    this.reportInteractionBusy?.()
  }

  private requestClose(): void {
    const context = ReaderCloseContext.from(this.state)
    this.chromeCloseRequested = true
    this.originalFeedbackEpoch += 1
    this.session.cancelOriginalPreparations()
    this.autoReadController.stop()
    this.saveController.close()
    this.invalidateChromeShow()
    this.onClose(context)
  }

  private thumbnailUnitIdentity(): string {
    const unit = this.state.unit
    return JSON.stringify([unit?.key.scope, unit?.key.work, unit?.key.unit, unit?.pageCount])
  }

  private thumbnailRailVisible(): boolean {
    return this.chromeVisible && this.thumbnailsVisible && this.active && this.state.phase === 'ready'
  }

  private toggleThumbnails(): void {
    const nextVisible = !this.thumbnailsVisible
    this.getUIContext().animateTo({ duration: 180, curve: Curve.FastOutSlowIn }, (): void => {
      this.thumbnailsVisible = nextVisible
    })
  }

  private requestChapter(direction: 'previous' | 'next', source: ReaderUnitKey): void {
    const current = this.session.snapshot()
    if (!this.chapterNavigationAvailable || this.chapterNavigationBusy || !this.active || this.closing ||
      this.chromeDisposed || this.chromeCloseRequested || current.phase !== 'ready' ||
      current.unit?.key.equals(source) !== true) return
    this.previewIndex = -1
    this.autoReadController.stop()
    this.onChapter(direction, source.copy())
  }

  private requestBoundaryChapter(direction: 'previous' | 'next', topology: number, navigation: number): void {
    const current = this.session.snapshot()
    const available = direction === 'previous' ? current.canPreviousUnit : current.canNextUnit
    if (!available || topology !== current.topologyRevision || navigation !== current.navigationRevision ||
      current.unit === null) return
    this.requestChapter(direction, current.unit.key)
  }

  private commitChromeVisible(visible: boolean): void {
    this.chromeVisible = visible
    if (!this.chromeVisible) this.previewIndex = -1
    this.onChromeVisible(this.chromeVisible)
    console.info(`[ReaderSurface] chrome=${this.chromeVisible}`)
  }

  private async prepareChromeShow(epoch: number,
    gate: (isCurrent: () => boolean) => Promise<boolean>): Promise<void> {
    const isCurrent = (): boolean => epoch === this.chromeEpoch && this.active && !this.closing &&
      !this.chromeDisposed && !this.chromeCloseRequested
    try {
      const ready = await gate(isCurrent)
      if (ready && isCurrent()) this.commitChromeVisible(true)
    } catch (_) {
      // A failed host preparation leaves chrome hidden; no unhandled rejection.
    } finally {
      if (epoch === this.chromeEpoch) this.chromeShowPending = false
    }
  }

  private toggleChrome(): void {
    if (!this.active || this.closing || this.chromeDisposed || this.chromeCloseRequested || this.chromeShowPending) return
    const gate = this.beforeShowChrome
    if (this.chromeVisible || gate === null) {
      this.commitChromeVisible(!this.chromeVisible)
      return
    }
    this.chromeShowPending = true
    void this.prepareChromeShow(++this.chromeEpoch, gate)
  }

  private pageTap(x: number, y: number): ReaderTapAction {
    if (!this.active || this.closing || this.chromeDisposed || this.chromeCloseRequested ||
      this.entryTransition?.pending() || this.state.phase !== 'ready' || this.menuVisible ||
      this.shareBusy || this.saveBusy || this.informationBusy || this.tapZonePreviewVisible || this.previewIndex >= 0 ||
      this.inputTopology !== this.state.topologyRevision ||
      !Number.isFinite(x) || !Number.isFinite(y)) return 'none'
    const continuous = this.state.policy.layout === 'continuous'
    const session = this.session
    const topology = this.state.topologyRevision
    const navigation = this.state.navigationRevision
    const sessionNavigation = session.snapshot().navigationRevision
    const action: ReaderTapAction = this.tapZoneResolver !== null
      ? this.tapZoneResolver(x, y, this.state.policy.layout)
      : continuous || (x >= 1 / 3 && x <= 2 / 3) ? 'menu' : x < 1 / 3 ? 'left' : 'right'
    if (!this.active || this.closing || this.chromeDisposed || this.chromeCloseRequested ||
      this.session !== session || this.state.topologyRevision !== topology ||
      this.state.navigationRevision !== navigation || session.snapshot().navigationRevision !== sessionNavigation) return 'none'
    if (action === 'menu') { this.toggleChrome(); return 'menu' }
    if (continuous || action === 'none') return action
    const previous = action === 'previous' ||
      (action === 'left' && this.state.policy.direction === 'ltr') ||
      (action === 'right' && this.state.policy.direction === 'rtl')
    this.requestMove(previous ? 'previous' : 'next')
    return action
  }

  private retry(topology: number, key: string, slot: number, request: number): void {
    void this.session.retryItem(topology, key, slot, request)
  }

  private resolveNotice(topology: number, navigation: number, key: string,
    slot: number, request: number, noticeId: string): Promise<boolean> {
    return this.session.resolveNoticeItem(topology, navigation, key, slot, request, noticeId)
  }

  private externalMove(intent: ReaderMoveIntent): boolean {
    if (this.entryTransition?.phase === 'layout' || !this.active || this.state.phase !== 'ready' ||
      this.touching || this.menuVisible || this.shareBusy || this.saveBusy || this.informationBusy ||
      this.tapZonePreviewVisible || this.previewIndex >= 0 ||
      this.inputTopology !== this.state.topologyRevision || this.inputLocked) return false
    return this.requestMove(intent)
  }

  private requestMove(intent: ReaderMoveIntent): boolean {
    const before = this.session.snapshot()
    if (this.pageTurnAnimation && before.policy.layout !== 'continuous' &&
      before.topologyRevision === this.state.topologyRevision &&
      before.navigationRevision === this.state.navigationRevision &&
      before.displayIndex === this.state.displayIndex) {
      const target = before.displayIndex + (intent === 'next' ? 1 : -1)
      if (target < 0 || target >= before.displayCount) return false
      this.pagerCommand = new ReaderPagerCommand(
        ++this.pagerCommandSerial,
        target,
        before.topologyRevision,
        before.navigationRevision,
      )
      return true
    }
    const navigation = before.navigationRevision
    this.session.move(intent)
    return this.session.snapshot().navigationRevision !== navigation
  }

  private reportInputLock(locked: boolean, topology: number): void {
    if (topology !== this.state.topologyRevision) return
    this.inputTopology = topology
    this.inputLocked = locked
    this.reportInteractionBusy()
    this.syncAutoRead()
  }

  private validTapZonePreviewRegions(): ReaderTapZonePreviewRegion[] {
    return this.tapZonePreviewRegions.filter((region: ReaderTapZonePreviewRegion): boolean => region.valid())
  }

  private tapZonePreviewColor(action: ReaderTapAction): ResourceColor {
    if (action === 'previous') return '#CCFF7733'
    if (action === 'next') return '#CC3FAE58'
    if (action === 'left') return '#CC7D1128'
    if (action === 'right') return '#CC5F8F99'
    return '#CC756872'
  }

  private tapZonePreviewLabel(action: ReaderTapAction): Resource {
    if (action === 'previous') return $r('app.string.rkit_previous_page')
    if (action === 'next') return $r('app.string.rkit_next_page')
    if (action === 'left') return $r('app.string.rkit_tap_left')
    if (action === 'right') return $r('app.string.rkit_tap_right')
    return $r('app.string.rkit_tap_menu')
  }

  private dismissTapZonePreview(): void {
    if (!this.tapZonePreviewVisible) return
    this.tapZonePreviewVisible = false
    this.reportInteractionBusy()
    this.syncAutoRead()
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // The existing cell feedback stays above the optional source preview.
      // The preview's declared coverage controls its fade beneath the original image.
      if (this.entryTransition !== null && this.entryPreview !== null) {
        ReaderEntryPreview({ entry: this.entryTransition, source: this.entryPreview })
      }
      // This content owns a black canvas even when its host (or the separate Lab) is light.
      WithTheme({ colorMode: ThemeColorMode.DARK }) {
        if (this.state.policy.layout === 'continuous') {
          ReaderContinuousSurface({
            imageInterpolation: this.imageInterpolation,
            pageGap: this.pageGap,
            snapshot: this.state, active: this.active,
            zoomResetCommand: this.zoomResetCommand,
            entryTransition: this.entryTransition,
            onInputLockChange: (locked: boolean, topology: number): void => { this.reportInputLock(locked, topology) },
            onZoomedChange: (zoomed: boolean, topology: number, navigation: number): void => {
              this.reportZoomed(zoomed, topology, navigation)
            },
            onBoundary: (direction: 'previous' | 'next', topology: number, navigation: number): void => {
              this.requestBoundaryChapter(direction, topology, navigation)
            },
            onTap: (x: number, y: number): ReaderTapAction => this.pageTap(x, y),
            onRange: (start: number, end: number, topology: number, navigation: number): void => {
              this.session.setContinuousRange(start, end, topology, navigation)
            },
            onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
              this.session.reportPresentation(slot, request, success, width, height)
            },
            onRetry: (topology: number, key: string, slot: number, request: number): void => {
              this.retry(topology, key, slot, request)
            },
            onNoticeAction: (topology: number, navigation: number, key: string, slot: number,
              request: number, noticeId: string): Promise<boolean> => {
              return this.resolveNotice(topology, navigation, key, slot, request, noticeId)
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
            imageInterpolation: this.imageInterpolation,
            pageGap: this.pageGap,
            snapshot: this.state, active: this.active,
            zoomResetCommand: this.zoomResetCommand,
            command: this.pagerCommand,
            entryTransition: this.entryTransition,
            onInputLockChange: (locked: boolean, topology: number): void => { this.reportInputLock(locked, topology) },
            onZoomedChange: (zoomed: boolean, topology: number, navigation: number): void => {
              this.reportZoomed(zoomed, topology, navigation)
            },
            onBoundary: (direction: 'previous' | 'next', topology: number, navigation: number): void => {
              this.requestBoundaryChapter(direction, topology, navigation)
            },
            onTap: (x: number, y: number): void => { this.pageTap(x, y) },
            onSelect: (index: number, topology: number, navigation: number): void => {
              this.session.selectDisplay(index, topology, navigation)
            },
            onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
              this.session.reportPresentation(slot, request, success, width, height)
            },
            onRetry: (topology: number, key: string, slot: number, request: number): void => {
              this.retry(topology, key, slot, request)
            },
            onNoticeAction: (topology: number, navigation: number, key: string, slot: number,
              request: number, noticeId: string): Promise<boolean> => {
              return this.resolveNotice(topology, navigation, key, slot, request, noticeId)
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
          Text($r('app.string.rkit_catalog_failed')).fontColor(this.canvasForeground).fontSize(16)
          Button($r('app.string.rkit_retry')).height(40).constraintSize({ minWidth: 120 })
            .backgroundColor(this.accent).fontColor(Color.White)
            .onClick((): void => { void this.session.retry() })
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(24)
      }
      if (this.hostStatusVisible && this.hostStatusText.length > 0) {
        Row({ space: 8 }) {
          if (this.hostStatusBusy) {
            LoadingProgress().width(18).height(18).color(Color.White)
          } else {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(18).fontColor([Color.White])
          }
          Text(this.hostStatusText).fontSize(12).fontColor(Color.White).maxLines(2)
        }.padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#CC000000').borderRadius(20)
          .position({ x: 16, y: this.topInset + 72 }).hitTestBehavior(HitTestMode.None)
          .id('rkit-host-status')
      }
      if (this.tapZonePreviewVisible) {
        this.TapZonePreview()
      }
      // Keep the current unit's thumbnail window mounted while the strip or chrome is hidden.
      // Height clipping matches the production readers and preserves already decoded previews
      // without moving cache ownership into reader-kit.
      if (this.state.unit !== null) {
        Column() {
          ForEach([this.thumbnailUnitIdentity()], (_identity: string) => {
            ReaderThumbnailRail({ session: this.session, snapshot: this.state, accent: this.accent,
              previewIndex: this.previewIndex,
              onSeek: (index: number, unit: ReaderUnitKey, navigation: number): void => {
                this.session.seekSource(index, unit, navigation)
              },
            })
          }, (identity: string): string => readerElementKey(identity))
        }.width('100%').height(this.thumbnailRailVisible() ? 156 : 0)
          .padding({ top: this.thumbnailRailVisible() ? 8 : 0, bottom: this.thumbnailRailVisible() ? 8 : 0 })
          .margin({ bottom: this.bottomInset + 112 }).backgroundColor('#CC000000').clip(true)
          .hitTestBehavior(this.thumbnailRailVisible() ? HitTestMode.Default : HitTestMode.None)
          .id('rkit-thumbnail-rail-wrapper')
      }
      if (this.chromeVisible) {
        ReaderChrome({ snapshot: this.state, active: this.active, topInset: this.topInset,
          bottomInset: this.bottomInset, accent: this.accent, onClose: (): void => this.requestClose(),
          thumbnailsVisible: this.thumbnailsVisible,
          chapterNavigationAvailable: this.chapterNavigationAvailable,
          chapterNavigationBusy: this.chapterNavigationBusy,
          onChapter: (direction: 'previous' | 'next', source: ReaderUnitKey): void => {
            this.requestChapter(direction, source)
          },
          shareAvailable: this.imageShare !== null, shareBusy: this.shareBusy,
          saveAvailable: this.imageSave !== null, saveBusy: this.saveBusy,
          autoReadAvailable: this.autoReadAvailable, autoReadEnabled: this.autoReadEnabled,
          cropAvailable: this.cropAvailable,
          enhancementVisible: this.enhancementVisible(),
          enhancementProcessing: this.enhancementProcessing(),
          enhancementApplied: this.enhancementApplied(),
          hostSettingsAvailable: this.hostSettingsAvailable,
          onHostSettings: (): void => { this.onHostSettings() },
          externalOpenAvailable: this.externalOpenAvailable,
          onExternalOpen: (source: ReaderUnitKey): void => { this.onExternalOpen(source) },
          hostActions: this.hostActions,
          onHostAction: (id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number): void => {
            this.onHostAction(id, source, navigation, sourceIndex)
          },
          hostCenterActionAvailable: this.hostCenterActionAvailable,
          hostCenterActionLabel: this.hostCenterActionLabel,
          onHostCenterAction: (source: ReaderUnitKey, navigation: number): void => {
            this.onHostCenterAction(source, navigation)
          },
          onCrop: (): void => { this.toggleCrop() },
          originalAvailable: this.session.originalSelectionSupported(),
          onOriginal: (frames: ReaderPagedFrame[], unit: ReaderUnitKey, navigation: number, enabled: boolean): void => {
            void this.selectOriginal(frames, unit, navigation, enabled)
          },
          onAutoRead: (): void => { this.toggleAutoRead() },
          onSave: (choice: ReaderImageSaveChoice): void => { void this.saveImage(choice) },
          informationBusy: this.informationBusy,
          informationPreparing: this.informationBusy && !this.informationPresented,
          informationAvailable: this.session.informationSupported(),
          zoomResetAvailable: this.zoomed,
          onResetZoom: (source: ReaderUnitKey, navigation: number): void => { this.resetZoom(source, navigation) },
          onReload: (frame: ReaderPagedFrame, _unit: ReaderUnitKey, topology: number, navigation: number,
            itemKey: string): void => {
            void this.session.reloadItem(topology, navigation, itemKey, frame.slotId, frame.asset.requestId)
          },
          onInformation: (frame: ReaderPagedFrame): void => { void this.showInformation(frame) },
          onShare: (): void => { void this.shareImage() },
          onMenuVisible: (visible: boolean): void => {
            this.menuVisible = visible; this.reportInteractionBusy(); this.syncAutoRead()
          },
          onThumbnails: (): void => { this.toggleThumbnails() },
          onPolicy: (policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent): void => {
            this.applyPolicy(policy, intent)
          },
          onShiftSpread: (unit: ReaderUnitKey, topology: number, navigation: number): void => {
            this.session.shiftSpread(unit, topology, navigation)
          },
          onPreview: (index: number, unit: ReaderUnitKey | null, navigation: number): void => {
            this.previewIndex = this.active && this.chromeVisible && unit !== null &&
              this.state.unit?.key.equals(unit) && this.state.navigationRevision === navigation ? index : -1
            this.syncAutoRead()
            console.info(`[ReaderSurface] preview_source=${this.previewIndex} reading_source=${this.state.anchor?.sourceIndexHint ?? -1}`)
          },
          onSeek: (index: number, unit: ReaderUnitKey, navigation: number): void => {
            const accepted = this.session.seekSource(index, unit, navigation)
            console.info(`[ReaderSurface] seek_source=${index} accepted=${accepted}`)
          },
        })
      } else if ((this.showPageNumber || this.enhancementVisible()) &&
        this.state.unit !== null && this.state.unit.pageCount > 0) {
        ReaderPageStatus({ value: `${(this.state.anchor?.sourceIndexHint ?? 0) + 1} / ${this.state.unit.pageCount}`,
          bottomMargin: this.bottomInset + 8, showPageNumber: this.showPageNumber,
          showEnhancement: this.enhancementVisible(), enhancementProcessing: this.enhancementProcessing(),
          enhancementApplied: this.enhancementApplied(), accent: this.accent })
      }
    }.width('100%').height('100%').backgroundColor(this.canvasBackground).id('rkit-reading-surface')
      .onTouch((event: TouchEvent): void => {
        this.touching = event.type !== TouchType.Up && event.type !== TouchType.Cancel
        this.reportInteractionBusy()
        this.syncAutoRead()
      })
  }

  @Builder
  private TapZonePreview() {
    Stack() {
      ForEach(this.validTapZonePreviewRegions(), (region: ReaderTapZonePreviewRegion) => {
        Stack({ alignContent: Alignment.Center }) {
          Text(this.tapZonePreviewLabel(region.action))
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .backgroundColor('#99000000').borderRadius(999)
        }
          .position({ x: `${region.left * 100}%`, y: `${region.top * 100}%` })
          .width(`${(region.right - region.left) * 100}%`)
          .height(`${(region.bottom - region.top) * 100}%`)
          .backgroundColor(this.tapZonePreviewColor(region.action))
          .id(`rkit-tap-zone-${region.key()}`)
      }, (region: ReaderTapZonePreviewRegion): string => readerElementKey(region.key()))
    }
      .width('100%').height('100%').hitTestBehavior(HitTestMode.Block)
      .onClick((): void => { this.dismissTapZonePreview() })
      .id('rkit-tap-zone-preview')
  }
}
