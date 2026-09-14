import { ReaderAssetNotice } from '@reader-kit/core'

/** Host-authored suppressed-content material. The host owns the reason and recovery action. */
@ComponentV2
export struct ReaderAssetNoticePanel {
  @Require @Param notice: ReaderAssetNotice
  @Require @Param page: number
  @Param compact: boolean = false
  @Param actionBusy: boolean = false
  @Event onAction: () => void = () => {}

  @Builder
  private BackgroundLayer() {
    if (this.notice.previewUri.length > 0) {
      Image(this.notice.previewUri)
        .width('100%').height('100%').objectFit(ImageFit.Contain)
        .scale({ x: 1.04, y: 1.04 }).blur(48).opacity(0.92).renderGroup(true)
      Column().width('100%').height('100%').backgroundColor('#66000000')
    } else {
      Column().width('100%').height('100%').backgroundColor('#CC303236')
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.BackgroundLayer()
      Column({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(this.compact ? 32 : 44).fontColor([Color.White])
        Text(this.notice.title)
          .fontSize(14).fontColor(Color.White).fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center).maxLines(2)
        Text(this.notice.message)
          .fontSize(12).fontColor('#CCFFFFFF').textAlign(TextAlign.Center).maxLines(3)
        Text(`P${this.page}`)
          .fontSize(12).fontColor('#BBFFFFFF').textAlign(TextAlign.Center).maxLines(1)
        Button(this.notice.actionLabel)
          .type(ButtonType.Capsule).height(36).constraintSize({ minWidth: 104 })
          .padding({ left: 20, right: 20 }).fontSize(14)
          .fontColor(Color.White).backgroundColor('#665F6368')
          .enabled(!this.actionBusy).id(`rkit-notice-action-page-${this.page}`)
          .onClick((): void => { this.onAction() })
      }
      .width('100%').constraintSize({ maxWidth: this.compact ? 196 : 280 })
      .padding(16).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height(this.compact ? 220 : '100%').clip(true)
    .hitTestBehavior(HitTestMode.Default).id(`rkit-notice-page-${this.page}`)
  }
}
