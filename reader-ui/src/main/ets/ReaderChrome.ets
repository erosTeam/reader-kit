import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderDisplayPolicy, ReaderUnitKey,
  ReaderImageSaveChoice, ReaderImageSaveTarget } from '@reader-kit/core'
import { uiMaterial } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

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
  @Param autoReadEnabled: boolean = false
  @Event onAutoRead: () => void = () => {}
  @Event onSave: (choice: ReaderImageSaveChoice) => void = () => {}
  @Param informationBusy: boolean = false
  @Param informationPreparing: boolean = false
  @Param informationAvailable: boolean = false
  @Event onInformation: (frame: ReaderPagedFrame) => void = () => {}
  @Event onShare: () => void = () => {}
  @Event onThumbnails: () => void = () => {}
  @Event onMenuVisible: (visible: boolean) => void = () => {}
  @Event onClose: () => void = () => {}
  @Event onPolicy: (policy: ReaderDisplayPolicy) => void = () => {}
  @Event onSeek: (index: number, unit: ReaderUnitKey, navigation: number) => void = () => {}
  @Event onPreview: (index: number, unit: ReaderUnitKey | null, navigation: number) => void = () => {}
  @Local private preview: number = -1
  @Local private moreShown: boolean = false
  @Local private saveMenuShown: boolean = false
  private saveLeft: ReaderImageSaveTarget | null = null
  private saveRight: ReaderImageSaveTarget | null = null
  private saveBoth: ReaderImageSaveTarget | null = null
  private saveLeftIndex: number = -1
  private saveRightIndex: number = -1
  private seekUnit: ReaderUnitKey | null = null
  private seekNavigation: number = -1

  @Monitor('snapshot', 'active')
  onSnapshotChanged(): void {
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

  private setLayout(layout: 'single' | 'spread' | 'continuous'): void {
    const policy = this.snapshot.policy.copy()
    policy.layout = layout
    this.onPolicy(policy)
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
    if (!this.active || this.saveBusy || this.shareBusy || this.informationBusy) return
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
    if (this.active && !this.saveBusy && !this.shareBusy && !this.informationBusy &&
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

  private selectInformation(frame: ReaderPagedFrame): void {
    this.moreShown = false
    this.onInformation(frame)
  }

  @Builder
  private InformationChoice() {
    Menu() {
      ForEach(this.snapshot.frames, (frame: ReaderPagedFrame, index: number) => {
        MenuItem({ content: index === 0 ? $r('app.string.rkit_info_left', frame.part.sourceIndex + 1) :
          $r('app.string.rkit_info_right', frame.part.sourceIndex + 1) })
          .enabled(frame.asset.kind === 'original' && frame.asset.phase === 'displayed' && frame.asset.informationAvailable)
          .id(`rkit-info-source-${frame.part.sourceIndex}`)
          .onClick((): void => { this.selectInformation(frame) })
      }, (frame: ReaderPagedFrame): string => `${frame.slotId}`)
    }
  }

  @Builder
  private MoreMenu() {
    Menu() {
      if (this.snapshot.frames.length > 1) {
        MenuItem({ content: $r('app.string.rkit_image_info'), builder: this.InformationChoice })
          .id('rkit-image-info')
      } else {
        MenuItem({ content: $r('app.string.rkit_image_info') }).id('rkit-image-info')
          .onClick((): void => {
            const frame = this.informationFrames()[0]
            if (frame !== undefined) this.selectInformation(frame)
          })
      }
    }
  }

  @Builder
  private RuntimeMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rkit_single') }).onClick((): void => { this.setLayout('single') })
      MenuItem({ content: $r('app.string.rkit_spread') }).onClick((): void => { this.setLayout('spread') })
      MenuItem({ content: $r('app.string.rkit_continuous') }).onClick((): void => { this.setLayout('continuous') })
      MenuItem({ content: this.snapshot.policy.direction === 'ltr' ? $r('app.string.rkit_rtl') : $r('app.string.rkit_ltr') })
        .enabled(this.snapshot.policy.layout !== 'continuous')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.direction = policy.direction === 'ltr' ? 'rtl' : 'ltr'
          this.onPolicy(policy)
        })
      MenuItem({ content: this.snapshot.policy.firstPageAlone ? $r('app.string.rkit_cover_off') : $r('app.string.rkit_cover_on') })
        .enabled(this.snapshot.policy.layout === 'spread')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.firstPageAlone = !policy.firstPageAlone
          this.onPolicy(policy)
        })
      MenuItem({ content: this.snapshot.policy.splitWidePages ? $r('app.string.rkit_split_off') : $r('app.string.rkit_split_on') })
        .enabled(this.snapshot.policy.layout === 'single')
        .onClick((): void => {
          const policy = this.snapshot.policy.copy()
          policy.splitWidePages = !policy.splitWidePages
          this.onPolicy(policy)
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
              .enabled(this.active && this.snapshot.phase === 'ready' && !this.shareBusy && !this.saveBusy)
              .onClick(this.onShare)
          }
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .id('rkit-runtime-settings').accessibilityText($r('app.string.rkit_runtime_settings'))
            .enabled(this.active && this.snapshot.phase === 'ready')
            .bindMenu(this.RuntimeMenu, {
              aboutToAppear: (): void => { this.onMenuVisible(true) },
              onDisappear: (): void => { this.onMenuVisible(false) },
            })
          if (this.informationAvailable) {
            Button({ type: ButtonType.Circle }) {
              if (this.informationPreparing) {
                LoadingProgress().width(22).height(22).color(Color.White)
              } else {
                SymbolGlyph($r('sys.symbol.dot_grid_2x2')).fontSize(22).fontColor([Color.White])
              }
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .id('rkit-more').accessibilityText($r('app.string.rkit_more'))
              .enabled(this.active && this.informationFrames().length > 0 && !this.informationBusy && !this.shareBusy && !this.saveBusy)
              .onClick((): void => { this.moreShown = true })
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
              .enabled(this.active && !this.saveBusy && !this.shareBusy && !this.informationBusy &&
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
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.book')).fontSize(22)
              .fontColor([this.snapshot.policy.layout === 'spread' ? this.accent : Color.White])
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .enabled(this.active && this.snapshot.phase === 'ready' && this.snapshot.policy.layout !== 'continuous')
            .id('rkit-toggle-spread').accessibilityText($r('app.string.rkit_spread'))
            .onClick((): void => { this.setLayout(this.snapshot.policy.layout === 'spread' ? 'single' : 'spread') })
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph(this.snapshot.policy.layout === 'continuous' ? $r('sys.symbol.scroll_vertical') :
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
