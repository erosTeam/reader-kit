/** Shared failure material only. The parent owns layout; the session owns retry. */
@ComponentV2
export struct ReaderFailurePanel {
  @Require @Param page: number
  @Param compact: boolean = false
  @Param retryEnabled: boolean = true
  @Event onRetry: () => void = () => {}

  build() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(this.compact ? 28 : 36)
        .fontColor([$r('sys.color.font_primary')])
      Text($r('app.string.rkit_image_failed'))
        .fontSize(14).fontColor($r('sys.color.font_primary'))
        .fontWeight(FontWeight.Medium).textAlign(TextAlign.Center).maxLines(2)
      Text($r('app.string.rkit_image_retry_hint'))
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center).maxLines(2)
      Text(`P${this.page}`)
        .fontSize(12).fontColor($r('sys.color.font_tertiary'))
        .textAlign(TextAlign.Center).maxLines(1)
      Button($r('app.string.rkit_retry'))
        .type(ButtonType.Capsule).height(40)
        .constraintSize({ minWidth: 120 })
        .padding({ left: 24, right: 24 }).fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .enabled(this.retryEnabled).id(`rkit-retry-page-${this.page}`)
        .onClick((): void => { this.onRetry() })
    }
    .width('100%').constraintSize({ maxWidth: this.compact ? 196 : 280 })
    .padding(16).backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
    .backgroundColor('#665F6368').borderRadius(24).clip(true)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Default).id(`rkit-failure-page-${this.page}`)
  }
}
