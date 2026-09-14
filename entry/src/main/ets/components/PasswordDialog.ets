/**
 * 密码输入弹窗（备份加密 / 恢复解密共用）：
 * 备份场景密码可选（留空 = 不加密，仅完整性校验），输入则要求至少 4 位；
 * 恢复场景密码必填（无密码备份不经过本弹窗，由调用方 peekHeader 分流）。
 * 备份场景（showPluginOption=true）额外提供「包含已安装插件」勾选项。
 * 由 SettingsPage 以 CustomDialogController 动态创建（回调捕获当次操作语义）。
 */

@CustomDialog
export struct PasswordDialog {
  controller?: CustomDialogController;
  /** 弹窗标题（如「设置备份密码」「输入备份密码」） */
  title: string = '';
  confirmText: string = '确定';
  /** 密码是否可留空（备份场景 true，恢复场景 false） */
  passwordOptional: boolean = false;
  /** 是否显示「包含已安装插件」勾选（仅备份场景） */
  showPluginOption: boolean = false;
  onCancel: () => void = (): void => {
  };
  onConfirm: (password: string, includePlugins: boolean) => void = (p: string, i: boolean): void => {
  };
  @State password: string = '';
  @State includePlugins: boolean = false;

  private canConfirm(): boolean {
    if (this.passwordOptional) {
      return this.password.length === 0 || this.password.length >= 4;
    }
    return this.password.length >= 4;
  }

  private confirmStyle(): Resource {
    return this.canConfirm() ? $r('app.color.brand') : $r('app.color.font_fourth');
  }

  private submit(): void {
    if (this.canConfirm()) {
      this.onConfirm(this.password, this.includePlugins);
      this.controller?.close();
    }
  }

  build() {
    Column({ space: 16 }) {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')

      TextInput({ placeholder: this.passwordOptional ? '可选：至少 4 位密码，留空则不加密' : '输入至少 4 位密码' })
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
          this.submit();
        })

      Text(this.hintText())
        .fontSize(11)
        .lineHeight(15)
        .fontColor(this.hintColor())
        .width('100%')

      if (this.showPluginOption) {
        Row() {
          Column({ space: 2 }) {
            Text('包含已安装插件')
              .fontSize(14)
              .fontColor($r('app.color.font_primary'))
            Text('备份插件文件与配置，恢复后免重新导入')
              .fontSize(11)
              .fontColor($r('app.color.font_tertiary'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.includePlugins })
            .width(40)
            .height(24)
            .selectedColor($r('app.color.brand'))
            .onChange((on: boolean): void => {
              this.includePlugins = on;
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
          .backgroundColor(this.confirmStyle())
          .enabled(this.canConfirm())
          .layoutWeight(1)
          .height(40)
          .onClick((): void => {
            this.submit();
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

  private hintText(): string {
    if (this.passwordOptional && this.password.length === 0) {
      return '不设密码：备份不加密，服务商密钥与插件凭证将写入备份文件，请妥善保管、勿外传';
    }
    return '密码用于加密备份文件（含服务商密钥），丢失后备份无法恢复';
  }

  private hintColor(): Resource {
    if (this.passwordOptional && this.password.length === 0) {
      return $r('app.color.warning');
    }
    return $r('app.color.font_tertiary');
  }
}
