/**
 * 密码输入弹窗（备份加密 / 恢复解密共用）：
 * 密码 TextInput + 确认/取消；confirm 只在非空时可用。
 * 备份场景（showImageOption=true）额外提供「包含图片翻译原图」勾选项。
 * 由 SettingsPage 以 CustomDialogController 动态创建（回调捕获当次操作语义）。
 */
@CustomDialog
export struct PasswordDialog {
  controller?: CustomDialogController;
  /** 弹窗标题（如「设置备份密码」「输入备份密码」） */
  title: string = '';
  confirmText: string = '确定';
  /** 是否显示「包含图片」勾选（仅备份场景） */
  showImageOption: boolean = false;
  onCancel: () => void = (): void => {
  };
  onConfirm: (password: string, includeImages: boolean) => void = (p: string, i: boolean): void => {
  };
  @State password: string = '';
  @State includeImages: boolean = false;

  build() {
    Column({ space: 16 }) {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')

      TextInput({ placeholder: '输入至少 4 位密码' })
        .type(InputType.Password)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
        .placeholderColor($r('app.color.font_fourth'))
        .backgroundColor($r('app.color.bg_container'))
        .borderRadius(12)
        .height(44)
        .width('100%')
        .onChange((value: string): void => {
          this.password = value;
        })
        .onSubmit((): void => {
          if (this.password.length >= 4) {
            this.onConfirm(this.password, this.includeImages);
            this.controller?.close();
          }
        })

      Text('密码用于加密备份文件（含服务商密钥），丢失后备份无法恢复')
        .fontSize(11)
        .lineHeight(15)
        .fontColor($r('app.color.font_tertiary'))
        .width('100%')

      if (this.showImageOption) {
        Row() {
          Column({ space: 2 }) {
            Text('包含图片翻译的原图')
              .fontSize(14)
              .fontColor($r('app.color.font_primary'))
            Text('勾选后备份文件会明显变大（每张约 0.3MB）')
              .fontSize(11)
              .fontColor($r('app.color.font_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.includeImages })
            .width(40)
            .height(24)
            .selectedColor($r('app.color.brand'))
            .onChange((on: boolean): void => {
              this.includeImages = on;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(14)
          .fontColor($r('app.color.font_secondary'))
          .backgroundColor($r('app.color.bg_container'))
          .layoutWeight(1)
          .height(40)
          .onClick((): void => {
            this.onCancel();
            this.controller?.close();
          })
        Button(this.confirmText)
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor(this.password.length >= 4 ? $r('app.color.brand') : $r('app.color.font_fourth'))
          .enabled(this.password.length >= 4)
          .layoutWeight(1)
          .height(40)
          .onClick((): void => {
            this.onConfirm(this.password, this.includeImages);
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: 340 })
    .padding(16)
    .borderRadius(24)
    .backgroundColor($r('app.color.card_bg'))
  }
}
