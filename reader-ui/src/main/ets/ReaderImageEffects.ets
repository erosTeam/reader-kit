/** Optional display-only effects. No cache, asset, gesture or policy ownership. */
export class ReaderImageEffects {
  grayscale: boolean = false
  inverted: boolean = false
  tint: boolean = false
  tintColor: ResourceColor = Color.Transparent
  blendMode: BlendMode = BlendMode.SRC_OVER
  dimOpacity: number = 0
}

/** Isolate blending to drawable pixels; loading, chrome and status remain siblings. */
@ComponentV2
export struct ReaderImageEffectsLayer {
  @Param effects: ReaderImageEffects = new ReaderImageEffects()
  @BuilderParam content: () => void

  private hasEffects(): boolean {
    return this.effects.grayscale || this.effects.inverted || this.effects.tint || this.effects.dimOpacity > 0
  }

  build() {
    if (!this.hasEffects()) {
      // No display effect: the image/placeholder is the whole layer. Avoid
      // two wrapper Stacks and an offscreen-capable blend pass per page.
      this.content()
    } else {
      Stack() {
        Stack() {
          this.content()
        }.width('100%').height('100%')
          .grayscale(this.effects.grayscale ? 1 : 0)
          .invert(this.effects.inverted ? 1 : 0)
        if (this.effects.tint) {
          Column() {}.width('100%').height('100%').backgroundColor(this.effects.tintColor)
            .blendMode(this.effects.blendMode).hitTestBehavior(HitTestMode.None)
        }
        if (this.effects.dimOpacity > 0) {
          Column() {}.width('100%').height('100%').backgroundColor(Color.Black)
            .opacity(this.effects.dimOpacity).hitTestBehavior(HitTestMode.None)
        }
      }.width('100%').height('100%')
        .blendMode(BlendMode.SRC_OVER, this.effects.tint ? BlendApplyType.OFFSCREEN : BlendApplyType.FAST)
    }
  }
}
