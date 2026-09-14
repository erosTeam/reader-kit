import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderDisplayPolicy, ReaderUnitKey,
  ReaderImageSaveChoice, ReaderImageSaveTarget } from '@reader-kit/core'
import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import { ReaderHostAction } from './ReaderHostAction'

export type ReaderRuntimePolicyIntent = 'layout' | 'direction' | 'spread_layout' |
  'first_page_alone' | 'split_wide_pages'

/** Default overlay chrome. It emits intentions; it never opens a catalog or writes preferences. */
@ComponentV2
export struct ReaderChrome {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Param active: boolean = true
  @Param topInset: number = 0
  @Param bottomInset: number = 0
  @Param accent: ResourceColor = '#D93646'
  @Param thumbnailsVisible: boolean = false
  @Param shareAvailable: boolean = false
  @Param shareBusy: boolean = false
  @Param saveAvailable: boolean = false
  @Param saveBusy: boolean = false
  @Param autoReadAvailable: boolean = false
  @Param cropAvailable: boolean = false
  @Event onCrop: () => void = () => {}
  @Param originalAvailable: boolean = false
  @Event onOriginal: (frames: ReaderPagedFrame[], unit: ReaderUnitKey, navigation: number, enabled: boolean) => void = () => {}
  @Param autoReadEnabled: boolean = false
  @Event onAutoRead: () => void = () => {}
  @Event onSave: (choice: ReaderImageSaveChoice) => void = () => {}
  @Param informationBusy: boolean = false
  @Param informationPreparing: boolean = false
  @Param informationAvailable: boolean = false
  @Param reloadAvailable: boolean = true
  @Event onReload: (frame: ReaderPagedFrame, unit: ReaderUnitKey, topology: number, navigation: number,
    itemKey: string) => void = () => {}
  @Param chapterNavigationAvailable: boolean = false
  @Param chapterNavigationBusy: boolean = false
  @Event onChapter: (direction: 'previous' | 'next', source: ReaderUnitKey) => void = () => {}
  @Param hostSettingsAvailable: boolean = false
  @Event onHostSettings: () => void = () => {}
  @Param externalOpenAvailable: boolean = false
  @Event onExternalOpen: (source: ReaderUnitKey) => void = () => {}
  @Param hostActions: ReaderHostAction[] = []
  @Event onHostAction: (id: string, source: ReaderUnitKey, navigation: number, sourceIndex: number) => void = () => {}
  @Event onInformation: (frame: ReaderPagedFrame) => void = () => {}
  @Event onShare: () => void = () => {}
  @Event onThumbnails: () => void = () => {}
  @Event onMenuVisible: (visible: boolean) => void = () => {}
  @Event onClose: () => void = () => {}
  @Event onPolicy: (policy: ReaderDisplayPolicy, intent: ReaderRuntimePolicyIntent) => void = () => {}
  @Event onShiftSpread: (unit: ReaderUnitKey, topology: number, navigation: number) => void = () => {}
  @Event onSeek: (index: number, unit: ReaderUnitKey, navigation: number) => void = () => {}
  @Event onPreview: (index: number, unit: ReaderUnitKey | null, navigation: number) => void = () => {}
  @Local private preview: number = -1
  @Local private moreShown: boolean = false
  @Local private saveMenuShown: boolean = false
  @Local private originalMenuShown: boolean = false
  private originalFrames: ReaderPagedFrame[] = []
  private originalUnit: ReaderUnitKey | null = null
  private originalNavigation: number = -1
  private saveLeft: ReaderImageSaveTarget | null = null
  private saveRight: ReaderImageSaveTarget | null = null
  private saveBoth: ReaderImageSaveTarget | null = null
  private saveLeftIndex: number = -1
  private saveRightIndex: number = -1
  private seekUnit: ReaderUnitKey | null = null
  private seekNavigation: number = -1
  private moreUnit: ReaderUnitKey | null = null
  private moreTopology: number = -1
  private moreNavigation: number = -1

  @Monitor('snapshot', 'active')
  onSnapshotChanged(): void {
    if (this.moreShown && (!this.active || this.moreUnit !== null &&
      (this.snapshot.unit?.key.equals(this.moreUnit) !== true ||
        this.snapshot.topologyRevision !== this.moreTopology ||
        this.snapshot.navigationRevision !== this.moreNavigation))) this.moreShown = false
    if (this.originalMenuShown && (!this.active || !this.originalTargetsCurrent())) this.originalMenuShown = false
    if (this.saveMenuShown && (!this.active || !this.saveTargetsCurrent())) this.saveMenuShown = false
    if (!this.active || this.snapshot.phase !== 'ready' ||
      this.seekUnit !== null && (!this.snapshot.unit?.key.equals(this.seekUnit) ||
        this.snapshot.navigationRevision !== this.seekNavigation)) this.cancelSeek()
  }

  aboutToDisappear(): void { this.cancelSeek(); this.onMenuVisible(false) }

  private cancelSeek(): void {
    const hadPreview = this.seekUnit !== null
    this.preview = -1; this.seekUnit = null; this.seekNavigation = -1
    if (hadPreview) this.onPreview(-1, null, -1)
  }
  private count(): number { return this.snapshot.unit?.pageCount ?? 0 }
  private page(): number { return this.count() > 0 ? (this.snapshot.anchor?.sourceIndexHint ?? 0) + 1 : 0 }
  private value(): number { return this.preview >= 1 ? this.preview : this.page() }

  private beginSeek(): void {
    if (!this.active || this.snapshot.phase !== 'ready' || this.snapshot.unit === null) return
    this.seekUnit = this.snapshot.unit.key.copy()
    this.seekNavigation = this.snapshot.navigationRevision
  }

  private commitSeek(value: number): void {
    const unit = this.seekUnit
    const navigation = this.seekNavigation
    const current = this.active && this.snapshot.phase === 'ready' && unit !== null &&
      this.snapshot.unit?.key.equals(unit) && this.snapshot.navigationRevision === navigation
    if (current && unit !== null) this.onSeek(Math.round(value) - 1, unit, navigation)
    this.cancelSeek()
  }

  private sliderChanged(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) this.beginSeek()
    if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
      if (this.seekUnit !== null && this.preview !== Math.round(value)) {
        this.preview = Math.round(value)
        this.onPreview(this.preview - 1, this.seekUnit.copy(), this.seekNavigation)
      }
    } else if (mode === SliderChangeMode.Click) {
      if (this.seekUnit === null) this.beginSeek()
      this.commitSeek(value)
    } else if (mode === SliderChangeMode.End) this.commitSeek(value)
  }

  private setLayout(layout: 'single' | 'spread' | 'continuous', axis: 'horizontal' | 'vertical' = 'horizontal'): void {
    const policy = this.snapshot.policy.copy()
    policy.layout = layout
    policy.pagingAxis = axis
    this.onPolicy(policy, 'layout')
  }

  private toggleSpreadLayout(): void {
    const policy = this.snapshot.policy.copy()
    if (policy.layout !== 'spread') return
    policy.spreadLayout = policy.spreadLayout === 'joined' ? 'split' : 'joined'
    this.onPolicy(policy, 'spread_layout')
  }

  private canOriginal(frame: ReaderPagedFrame): boolean {
    const current = this.snapshot.frames.find(value => value.slotId === frame.slotId && value.asset.requestId === frame.asset.requestId)
    return current !== undefined && current.asset.kind === 'original' && (current.asset.variant === 'original' ||
      current.asset.phase === 'displayed' && current.asset.originalAvailable)
  }

  private originalTargetsCurrent(): boolean {
    return this.originalUnit !== null && this.snapshot.unit?.key.equals(this.originalUnit) === true &&
      this.originalNavigation === this.snapshot.navigationRevision &&
      this.originalFrames.length === this.snapshot.frames.length && this.originalFrames.every(frame =>
        this.snapshot.frames.some(current => current.slotId === frame.slotId &&
          current.asset.requestId === frame.asset.requestId))
  }

  private openOriginal(): void {
    if (!this.active || this.snapshot.originalPreparing || this.saveBusy || this.shareBusy || this.informationBusy ||
      this.snapshot.unit === null || !this.snapshot.frames.some(frame => this.canOriginal(frame))) return
    this.originalFrames = this.snapshot.frames.slice()
    this.originalUnit = this.snapshot.unit.key.copy()
    this.originalNavigation = this.snapshot.navigationRevision
    if (this.originalFrames.length > 1) { this.saveMenuShown = false; this.originalMenuShown = true }
    else this.selectOriginal(this.originalFrames)
  }

  private selectOriginal(frames: ReaderPagedFrame[]): void {
    this.originalMenuShown = false
    if (!this.active || this.snapshot.originalPreparing || !this.originalTargetsCurrent() || this.originalUnit === null ||
      frames.length === 0 || !frames.every(frame => this.canOriginal(frame))) return
    this.onOriginal(frames, this.originalUnit.copy(), this.originalNavigation,
      !frames.every(frame => frame.asset.variant === 'original'))
  }

  @Builder
  private OriginalMenu() {
    Menu() {
      ForEach(this.originalFrames, (frame: ReaderPagedFrame, index: number) => {
        MenuItem({ content: index === 0 ? $r('app.string.rkit_info_left', frame.part.sourceIndex + 1) :
          $r('app.string.rkit_info_right', frame.part.sourceIndex + 1),
          symbolEndIcon: frame.asset.variant === 'original' ? new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined })
          .id(`rkit-original-source-${frame.part.sourceIndex}`).enabled(this.canOriginal(frame))
          .onClick((): void => { this.selectOriginal([frame]) })
      }, (frame: ReaderPagedFrame): string => `${frame.slotId}`)
      MenuItem({ content: this.originalFrames.every(frame => frame.asset.variant === 'original') ?
        $r('app.string.rkit_original_disable_both') : $r('app.string.rkit_original_enable_both') })
        .id('rkit-original-both').enabled(this.originalFrames.every(frame => this.canOriginal(frame)))
        .onClick((): void => { this.selectOriginal(this.originalFrames) })
    }
  }

  private saveTarget(choice: ReaderImageSaveChoice): ReaderImageSaveTarget | null {
    return ReaderImageSaveTarget.from(this.snapshot, choice)
  }

  private saveTargetsCurrent(): boolean {
    const left = this.saveTarget('left'), right = this.saveTarget('right')
    return (this.saveLeft === null ? left === null : left !== null && this.saveLeft.equals(left)) &&
      (this.saveRight === null ? right === null : right !== null && this.saveRight.equals(right))
  }

  private openSave(): void {
    if (!this.active || this.saveBusy || this.shareBusy || this.informationBusy || this.snapshot.originalPreparing) return
    if (this.snapshot.policy.layout === 'spread' && this.snapshot.frames.length === 2) {
      this.saveLeftIndex = this.snapshot.frames[0].part.sourceIndex
      this.saveRightIndex = this.snapshot.frames[1].part.sourceIndex
      this.saveLeft = this.saveTarget('left')
      this.saveRight = this.saveTarget('right')
      this.saveBoth = this.saveTarget('both')
      this.saveMenuShown = this.saveLeft !== null || this.saveRight !== null
    } else if (this.saveTarget('current') !== null) this.onSave('current')
  }

  private selectSave(choice: ReaderImageSaveChoice, expected: ReaderImageSaveTarget | null): void {
    this.saveMenuShown = false
    const current = this.saveTarget(choice)
    if (this.active && !this.saveBusy && !this.shareBusy && !this.informationBusy && !this.snapshot.originalPreparing &&
      expected !== null && current !== null && expected.equals(current)) this.onSave(choice)
  }

  @Builder
  private SaveMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rkit_info_left', this.saveLeftIndex + 1) })
        .id('rkit-save-left').enabled(this.saveLeft !== null)
        .onClick((): void => { this.selectSave('left', this.saveLeft) })
      MenuItem({ content: $r('app.string.rkit_info_right', this.saveRightIndex + 1) })
        .id('rkit-save-right').enabled(this.saveRight !== null)
        .onClick((): void => { this.selectSave('right', this.saveRight) })
      MenuItem({ content: $r('app.string.rkit_save_both') })
        .id('rkit-save-both').enabled(this.saveBoth !== null)
        .onClick((): void => { this.selectSave('both', this.saveBoth) })
    }
  }

  private informationFrames(): ReaderPagedFrame[] {
    return this.snapshot.frames.filter((frame: ReaderPagedFrame): boolean =>
      frame.asset.kind === 'original' && frame.asset.phase === 'displayed' && frame.asset.informationAvailable)
  }

  private currentInformationFrame(slotId: number): ReaderPagedFrame | undefined {
    return this.informationFrames().find(frame => frame.slotId === slotId)
  }

  private selectInformation(frame: ReaderPagedFrame): void {
    const current = this.currentInformationFrame(frame.slotId)
    this.moreShown = false
    if (current !== undefined) this.onInformation(current)
  }

  private currentReloadFrame(slotId: number): ReaderPagedFrame | undefined {
    return this.snapshot.frames.find(frame => frame.slotId === slotId && frame.asset.page !== null &&
      (frame.asset.phase === 'displayed' || frame.asset.phase === 'failed'))
  }

  private selectReload(frame: ReaderPagedFrame): void {
    const current = this.currentReloadFrame(frame.slotId)
    const source = this.moreUnit
    const topology = this.moreTopology
    const navigation = this.moreNavigation
    const itemKey = this.snapshot.displayKeys[this.snapshot.displayIndex] ?? ''
    this.moreShown = false
    if (this.active && this.reloadAvailable && current !== undefined && source !== null && itemKey.length > 0 &&
      this.snapshot.phase === 'ready' && this.snapshot.unit?.key.equals(source) &&
      this.snapshot.topologyRevision === topology && this.snapshot.navigationRevision === navigation) {
      this.onReload(current, source.copy(), topology, navigation, itemKey)
    }
  }

  private selectChapter(direction: 'previous' | 'next'): void {
    const source = this.moreUnit
    const available = direction === 'previous' ? this.snapshot.canPreviousUnit : this.snapshot.canNextUnit
    this.moreShown = false
    if (this.active && this.chapterNavigationAvailable && !this.chapterNavigationBusy && available &&
      this.snapshot.phase === 'ready' && source !== null && this.snapshot.unit?.key.equals(source)) {
      this.onChapter(direction, source.copy())
    }
  }

  private selectExternalOpen(): void {
    const source = this.moreUnit
    this.moreShown = false
    if (this.active && this.externalOpenAvailable && this.snapshot.phase === 'ready' && source !== null &&
      this.snapshot.unit?.key.equals(source)) this.onExternalOpen(source.copy())
  }

  private selectHostAction(action: ReaderHostAction): void {
    const source = this.moreUnit
    const navigation = this.moreNavigation
    const sourceIndex = this.snapshot.anchor?.sourceIndexHint ?? -1
    this.moreShown = false
    if (this.active && action.enabled && !action.busy && this.snapshot.phase === 'ready' &&
      source !== null && this.snapshot.unit?.key.equals(source) &&
      this.snapshot.navigationRevision === navigation && sourceIndex >= 0) {
      this.onHostAction(action.id, source.copy(), navigation, sourceIndex)
    }
  }

  @Builder
  private InformationChoice() {
    Menu() {
      ForEach(this.snapshot.frames, (frame: ReaderPagedFrame, index: number) => {
        MenuItem({ content: index === 0 ? $r('app.string.rkit_info_left', frame.part.sourceIndex + 1) :
          $r('app.string.rkit_info_right', frame.part.sourceIndex + 1) })
          .enabled(this.currentInformationFrame(frame.slotId) !== undefined)
          .id(`rkit-info-source-${frame.part.sourceIndex}`)
          .onClick((): void => { this.selectInformation(frame) })
      }, (frame: ReaderPagedFrame): string => `${frame.slotId}`)
    }
  }

  @Builder
  private ReloadChoice() {
    Menu() {
      ForEach(this.snapshot.frames, (frame: ReaderPagedFrame, index: number) => {
        MenuItem({ content: index === 0 ? $r('app.string.rkit_info_left', frame.part.sourceIndex + 1) :
          $r('app.string.rkit_info_right', frame.part.sourceIndex + 1) })
          .enabled(this.currentReloadFrame(frame.slotId) !== undefined)
          .id(`rkit-reload-source-${frame.part.sourceIndex}`)
          .onClick((): void => { this.selectReload(frame) })
      }, (frame: ReaderPagedFrame): string => `${frame.slotId}`)
    }
  }

  @Builder
  private MoreMenu() {
    Menu() {
      if (this.reloadAvailable && this.snapshot.frames.length > 1) {
        MenuItem({ content: $r('app.string.rkit_reload_source'), builder: this.ReloadChoice })
          .id('rkit-reload-source-spread')
          .enabled(this.snapshot.frames.some(frame => this.currentReloadFrame(frame.slotId) !== undefined))
      } else if (this.reloadAvailable) {
        MenuItem({ content: $r('app.string.rkit_reload_source') }).id('rkit-reload-source')
          .enabled(this.snapshot.frames.some(frame => this.currentReloadFrame(frame.slotId) !== undefined))
          .onClick((): void => {
            const frame = this.snapshot.frames[0]
            if (frame !== undefined) this.selectReload(frame)
          })
      }
      if (this.informationAvailable && this.snapshot.frames.length > 1) {
        MenuItem({ content: $r('app.string.rkit_image_info'), builder: this.InformationChoice })
          .id('rkit-image-info-spread')
          .enabled(this.informationFrames().length > 0)
      } else if (this.informationAvailable) {
        MenuItem({ content: $r('app.string.rkit_image_info') }).id('rkit-image-info')
          .enabled(this.informationFrames().length > 0)
          .onClick((): void => {
            const frame = this.informationFrames()[0]
            if (frame !== undefined) this.selectInformation(frame)
          })
      }
      if (this.externalOpenAvailable) {
        MenuItem({ content: $r('app.string.rkit_open_external') }).id('rkit-open-external')
          .enabled(this.active && this.snapshot.phase === 'ready' && this.moreUnit !== null)
          .onClick((): void => { this.selectExternalOpen() })
      }
      ForEach(this.hostActions, (action: ReaderHostAction) => {
        MenuItem({ content: action.label,
          symbolEndIcon: action.checked ? new SymbolGlyphModifier($r('sys.symbol.checkmark')) : undefined })
          .id(`rkit-host-action-${action.id}`)
          .enabled(this.active && action.enabled && !action.busy && this.snapshot.phase === 'ready' &&
            this.moreUnit !== null && this.snapshot.navigationRevision === this.moreNavigation)
          .onClick((): void => { this.selectHostAction(action) })
      }, (action: ReaderHostAction): string => action.id)
      if (this.chapterNavigationAvailable) {
        MenuItem({ content: $r('app.string.rkit_previous_unit') }).id('rkit-previous-chapter')
          .enabled(this.active && this.snapshot.phase === 'ready' && !this.chapterNavigationBusy && this.snapshot.canPreviousUnit)
          .onClick((): void => { this.selectChapter('previous') })
        MenuItem({ content: $r('app.string.rkit_next_unit') }).id('rkit-next-chapter')
          .enabled(this.active && this.snapshot.phase === 'ready' && !this.chapterNavigationBusy && this.snapshot.canNextUnit)
          .onClick((): void => { this.selectChapter('next') })
      }
    }
  }

  @Builder
  private RuntimeMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rkit_single') }).onClick((): void => { this.setLayout('single') })
      MenuItem({ content: $r('app.string.rkit_vertical_paged') }).id('rkit-vertical-paged')
        .onClick((): void => { this.setLayout('single', 'vertical') })
      MenuItem({ content: $r('app.string.rkit_spread') }).onClick((): void => { this.setLayout('spread') })
      if (this.snapshot.policy.layout === 'spread') {
        MenuItem({ content: this.snapshot.policy.spreadLayout === 'joined' ?
          $r('app.string.rkit_spread_split') : $r('app.string.rkit_spread_joined') })
          .id('rkit-spread-layout').onClick((): void => { this.toggleSpreadLayout() })
      }
      MenuItem({ content: $r('app.string.rkit_continuous') }).onClick((): void => { this.setLayout('continuous') })
      if (this.cropAvailable) {
        MenuItem({ content: this.snapshot.cropEnabled ? $r('app.string.rkit_crop_off') : $r('app.string.rkit_crop_on') })
          .id('rkit-crop-toggle').enabled(this.active && this.snapshot.phase === 'ready')
          .onClick((): void => { this.onCrop() })
      }
      MenuItem({ content: this.snapshot.policy.direction === 'ltr' ? $r('app.string.rkit_rtl') : $r('app.string.rkit_ltr') })
        .enabled(this.snapshot.policy.layout !== 'continuous' && this.snapshot.policy.pagingAxis !== 'vertical')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.direction = policy.direction === 'ltr' ? 'rtl' : 'ltr'
          this.onPolicy(policy, 'direction')
        })
      MenuItem({ content: this.snapshot.policy.firstPageAlone ? $r('app.string.rkit_cover_off') : $r('app.string.rkit_cover_on') })
        .enabled(this.snapshot.policy.layout === 'spread')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.firstPageAlone = !policy.firstPageAlone
          this.onPolicy(policy, 'first_page_alone')
        })
      MenuItem({ content: this.snapshot.policy.splitWidePages ? $r('app.string.rkit_split_off') : $r('app.string.rkit_split_on') })
        .enabled(this.snapshot.policy.layout === 'single')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.splitWidePages = !policy.splitWidePages
          if (policy.splitWidePages) policy.rotateWidePages = false
          this.onPolicy(policy, 'split_wide_pages')
        })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack({ alignContent: Alignment.Center }) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .id('rkit-close').accessibilityText($r('app.string.rkit_close'))
            .onClick((): void => { this.onClose() })
          Blank()
          if (this.shareAvailable) {
            Button({ type: ButtonType.Circle }) {
              if (this.shareBusy) {
                LoadingProgress().width(22).height(22).color(Color.White)
              } else {
                SymbolGlyph($r('sys.symbol.share')).fontSize(22).fontColor([Color.White])
              }
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-share-image').accessibilityText($r('app.string.rkit_share_image'))
              .enabled(this.active && this.snapshot.phase === 'ready' && !this.shareBusy && !this.saveBusy && !this.snapshot.originalPreparing)
              .onClick(this.onShare)
          }
          if (this.hostSettingsAvailable) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([Color.White])
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-host-settings').accessibilityText($r('app.string.rkit_host_settings'))
              .enabled(this.active && this.snapshot.phase === 'ready')
              .onClick(this.onHostSettings)
          } else {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([Color.White])
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-runtime-settings').accessibilityText($r('app.string.rkit_runtime_settings'))
              .enabled(this.active && this.snapshot.phase === 'ready')
              .bindMenu(this.RuntimeMenu, {
                aboutToAppear: (): void => { this.onMenuVisible(true) },
                onDisappear: (): void => { this.onMenuVisible(false) },
              })
          }
          if (this.reloadAvailable || this.informationAvailable || this.externalOpenAvailable || this.chapterNavigationAvailable ||
            this.hostActions.length > 0) {
            Button({ type: ButtonType.Circle }) {
              if (this.informationPreparing) {
                LoadingProgress().width(22).height(22).color(Color.White)
              } else {
                SymbolGlyph($r('sys.symbol.dot_grid_2x2')).fontSize(22).fontColor([Color.White])
              }
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-more').accessibilityText($r('app.string.rkit_more'))
              .enabled(this.active && this.snapshot.phase === 'ready' && (this.reloadAvailable ||
                this.informationFrames().length > 0 || this.externalOpenAvailable ||
                this.hostActions.some((action: ReaderHostAction): boolean => action.enabled && !action.busy) ||
                this.chapterNavigationAvailable && this.snapshot.phase === 'ready') &&
                !this.chapterNavigationBusy && !this.informationBusy && !this.shareBusy && !this.saveBusy && !this.snapshot.originalPreparing)
              .onClick((): void => {
                this.moreUnit = this.snapshot.unit?.key.copy() ?? null
                this.moreTopology = this.snapshot.topologyRevision
                this.moreNavigation = this.snapshot.navigationRevision
                this.moreShown = true
              })
              .bindMenu(this.moreShown, this.MoreMenu, {
                placement: Placement.BottomRight,
                systemMaterial: deviceInfo.apiAvailable('26.0.0') ?
                  new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK }) : undefined,
                aboutToAppear: (): void => { this.onMenuVisible(true) },
                onDisappear: (): void => { this.moreShown = false; this.onMenuVisible(false) },
              })
          }
        }.width('100%').height(56).alignItems(VerticalAlign.Center)
        Text(`${this.page()} / ${this.count()}`).fontSize(14).fontColor(Color.White)
          .maxLines(1).textAlign(TextAlign.Center).hitTestBehavior(HitTestMode.None)
          .id('rkit-chrome-page')
      }.width('100%').height(this.topInset + 56)
        .padding({ top: this.topInset, left: 8, right: 8 })
        .backgroundColor('#CC000000').position({ x: 0, y: 0 })
        .id('rkit-chrome-top')

      Column({ space: 4 }) {
        Row({ space: 4 }) {
          Text(`${this.snapshot.policy.direction === 'rtl' ? this.count() : this.value()}`)
            .fontSize(14).fontColor(Color.White).constraintSize({ minWidth: 30 }).maxLines(1)
          Slider({ value: Math.max(1, this.value()), min: 1, max: Math.max(2, this.count()), step: 1,
            style: SliderStyle.InSet, reverse: this.snapshot.policy.direction === 'rtl' })
            .layoutWeight(1).trackColor('#33FFFFFF').selectedColor(this.accent)
            .enabled(this.active && this.snapshot.phase === 'ready' && this.count() > 1)
            .id('rkit-source-slider').accessibilityText($r('app.string.rkit_seek_page'))
            .onChange((value: number, mode: SliderChangeMode): void => { this.sliderChanged(value, mode) })
            .onTouch((event: TouchEvent): void => {
              if (event.type === TouchType.Cancel) this.cancelSeek()
            })
          Text(`${this.snapshot.policy.direction === 'rtl' ? this.value() : this.count()}`)
            .fontSize(14).fontColor(Color.White).constraintSize({ minWidth: 30 }).maxLines(1).textAlign(TextAlign.End)
        }.width('100%').alignItems(VerticalAlign.Center)
        Row() {
          if (this.saveAvailable) {
            Button({ type: ButtonType.Circle }) {
              if (this.saveBusy) {
                LoadingProgress().width(22).height(22).color(Color.White)
              } else {
                SymbolGlyph($r('sys.symbol.arrow_down_to_line')).fontSize(22).fontColor([Color.White])
              }
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-save-image').accessibilityText($r('app.string.rkit_save_image'))
              .enabled(this.active && !this.saveBusy && !this.shareBusy && !this.informationBusy && !this.snapshot.originalPreparing &&
                (this.saveTarget('current') !== null || this.saveTarget('left') !== null || this.saveTarget('right') !== null))
              .onClick((): void => { this.openSave() })
              .bindMenu(this.saveMenuShown, this.SaveMenu, {
                placement: Placement.TopRight,
                systemMaterial: deviceInfo.apiAvailable('26.0.0') ?
                  new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK }) : undefined,
                aboutToAppear: (): void => { this.onMenuVisible(true) },
                onDisappear: (): void => { this.saveMenuShown = false; this.onMenuVisible(false) },
              })
          }
          if (this.originalAvailable) {
            Button({ type: ButtonType.Circle }) {
              if (this.snapshot.originalPreparing) {
                LoadingProgress().width(22).height(22).color(this.accent)
              } else {
                SymbolGlyph($r('sys.symbol.arrow_outward_and_rectangle')).fontSize(22)
                  .fontColor([this.snapshot.frames.some(frame => frame.asset.variant === 'original') ? this.accent : Color.White])
              }
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-original-image').accessibilityText($r('app.string.rkit_original'))
              .enabled(this.active && !this.snapshot.originalPreparing && !this.saveBusy && !this.shareBusy &&
                !this.informationBusy && this.snapshot.frames.some(frame => this.canOriginal(frame)))
              .onClick((): void => { this.openOriginal() })
              .bindMenu(this.originalMenuShown, this.OriginalMenu, {
                placement: Placement.TopRight,
                systemMaterial: deviceInfo.apiAvailable('26.0.0') ?
                  new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK }) : undefined,
                aboutToAppear: (): void => { this.onMenuVisible(true) },
                onDisappear: (): void => { this.originalMenuShown = false; this.onMenuVisible(false) },
              })
          }
          if (this.autoReadAvailable) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.clock')).fontSize(22)
                .fontColor([this.autoReadEnabled ? this.accent : Color.White])
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .enabled(this.active && (this.autoReadEnabled ||
                this.snapshot.phase === 'ready' && this.snapshot.displayCount > 1))
              .id('rkit-auto-read')
              .accessibilityText(this.autoReadEnabled ? $r('app.string.rkit_auto_read_stop') : $r('app.string.rkit_auto_read_start'))
              .onClick(this.onAutoRead)
          }
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.rectangle_grid_2x1')).fontSize(22)
              .fontColor([this.thumbnailsVisible ? this.accent : Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready')
            .id('rkit-toggle-thumbnails').accessibilityText($r('app.string.rkit_thumbnail'))
            .onClick(this.onThumbnails)
          Blank()
          if (this.snapshot.policy.layout === 'spread') {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.transfer')).fontSize(22)
                .fontColor([this.snapshot.canShiftSpread ? Color.White : $r('sys.color.font_tertiary')])
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .enabled(this.active && this.snapshot.canShiftSpread)
              .id('rkit-shift-spread').accessibilityText($r('app.string.rkit_shift_spread'))
              .onClick((): void => {
                if (this.snapshot.unit !== null) this.onShiftSpread(this.snapshot.unit.key.copy(),
                  this.snapshot.topologyRevision, this.snapshot.navigationRevision)
              })
          }
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.book')).fontSize(22)
              .fontColor([this.snapshot.policy.layout === 'spread' ? this.accent : Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready' && this.snapshot.policy.layout !== 'continuous')
            .id('rkit-toggle-spread').accessibilityText($r('app.string.rkit_spread'))
            .onClick((): void => { this.setLayout(this.snapshot.policy.layout === 'spread' ? 'single' : 'spread') })
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(this.snapshot.policy.layout === 'continuous' || this.snapshot.policy.pagingAxis === 'vertical' ?
              $r('sys.symbol.scroll_vertical') :
              this.snapshot.policy.direction === 'rtl' ? $r('sys.symbol.arrow_left_and_square') : $r('sys.symbol.arrow_right_and_square')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready')
            .id('rkit-reading-mode').accessibilityText($r('app.string.rkit_runtime_settings'))
            .bindMenu(this.RuntimeMenu, {
              aboutToAppear: (): void => { this.onMenuVisible(true) },
              onDisappear: (): void => { this.onMenuVisible(false) },
            })
        }.width('100%').alignItems(VerticalAlign.Center)
      }.width('100%').height(this.bottomInset + 112)
        .padding({ left: 16, right: 16, top: 8, bottom: this.bottomInset + 8 })
        .backgroundColor('#CC000000').id('rkit-chrome-bottom')
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }
}
