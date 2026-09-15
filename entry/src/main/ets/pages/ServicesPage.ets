/**
 * 「翻译服务」一级页（NavDestination，自定义标题栏 + 手动避让状态栏）：
 *  - 翻译服务：进入服务商管理页（免费服务商添加/排序/开关/删除 + 用户服务商管理）
 *  - 离线翻译：进入离线翻译管理页（总开关 + 内置中英语言包开关）
 *  - 语音服务TTS：云端语音合成实例管理页（OpenAI /audio/speech 形状，偏好设置中选择生效）
 *  - 文字识别服务OCR：云端 OCR 实例管理页（传统 OCR + AI 视觉，拍照翻译时生效）
 *  - 插件服务：Bob 插件管理页（.bobplugin 导入 / 开关 / 删除，翻译类）
 */

import { OFFLINE_FEATURE_ENABLED } from '../services/OfflineTranslator';

@Component
export struct ServicesPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 沉浸式避让高度（vp）：全屏窗口下系统标题栏不避让状态栏，用自定义标题行 + 手动避让 */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;

  build() {
    NavDestination() {
      Column() {
        Blank().height(this.statusBarH)

        // 自定义标题栏（全屏窗口下 hideTitleBar + 手动避让状态栏）
        Row({ space: 12 }) {
          Stack() {
            Circle()
              .width(36)
              .height(36)
              .fill($r('app.color.card_bg'))
              .stroke($r('app.color.divider'))
              .strokeWidth(0.8)
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(17)
              .fontColor([$r('app.color.font_primary')])
          }
          .width(36)
          .height(36)
          .onClick(() => {
            this.pathStack.pop();
          })

          Text('翻译服务')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 12 }) {
            // ── 子项 1：翻译服务 ──
            Column() {
              Text('服务')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
                .margin({ left: 4, bottom: 8 })

              Row({ space: 12 }) {
                Text('译')
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(42)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .linearGradient({ angle: 135, colors: [['#0A59F7', 0.0], ['#0A9BFF', 1.0]] })
                Column({ space: 3 }) {
                  Text('翻译服务')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('免费服务商 · 已添加服务商管理')
                    .fontSize(12)
                    .lineHeight(17)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .padding(14)
              .alignItems(VerticalAlign.Center)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .onClick(() => {
                this.pathStack.pushPath({ name: 'BuiltinServicesPage' });
              })

              // ── 子项 2：离线翻译（端侧内置模型，独立管理页；引擎接入前隐藏） ──
              if (OFFLINE_FEATURE_ENABLED) {
                Row({ space: 12 }) {
                  Text('离')
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .width(42)
                    .height(42)
                    .textAlign(TextAlign.Center)
                    .borderRadius(12)
                    .linearGradient({ angle: 135, colors: [['#0BB36B', 0.0], ['#3ED598', 1.0]] })
                  Column({ space: 3 }) {
                    Text('离线翻译')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.font_primary'))
                    Text('端侧离线包 · 中英双向 · 无需联网')
                      .fontSize(12)
                      .lineHeight(17)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor($r('app.color.font_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(14)
                    .fontColor([$r('app.color.font_fourth')])
                }
                .width('100%')
                .margin({ top: 12 })
                .padding(14)
                .alignItems(VerticalAlign.Center)
                .borderRadius(16)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 0.8, color: $r('app.color.divider') })
                .onClick(() => {
                  this.pathStack.pushPath({ name: 'OfflineTranslatePage' });
                })
              }

              // ── 子项 3：语音服务 TTS（云端语音合成实例管理；偏好设置中选择生效） ──
              Row({ space: 12 }) {
                Text('音')
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(42)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .linearGradient({ angle: 135, colors: [['#FF6900', 0.0], ['#FF9F3D', 1.0]] })
                Column({ space: 3 }) {
                  Text('语音服务TTS')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('云端语音合成 · 朗读服务配置')
                    .fontSize(12)
                    .lineHeight(17)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .margin({ top: 12 })
              .padding(14)
              .alignItems(VerticalAlign.Center)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .onClick(() => {
                this.pathStack.pushPath({ name: 'TtsServicesPage' });
              })

              // ── 子项 4：文字识别服务 OCR（传统 OCR + AI 视觉实例管理） ──
              Row({ space: 12 }) {
                Text('文')
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(42)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .linearGradient({ angle: 135, colors: [['#00B2A9', 0.0], ['#3ED598', 1.0]] })
                Column({ space: 3 }) {
                  Text('文字识别服务OCR')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('腾讯 / 百度 OCR · AI 视觉模型')
                    .fontSize(12)
                    .lineHeight(17)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .margin({ top: 12 })
              .padding(14)
              .alignItems(VerticalAlign.Center)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .onClick(() => {
                this.pathStack.pushPath({ name: 'OcrServicesPage' });
              })

              // ── 子项 5：插件服务（Bob 插件导入/开关/删除） ──
              Row({ space: 12 }) {
                Text('插')
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(42)
                  .height(42)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .linearGradient({ angle: 135, colors: [['#7B5CFF', 0.0], ['#0A59F7', 1.0]] })
                Column({ space: 3 }) {
                  Text('插件服务')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('Bob 插件 · 从文件导入 · 参与引擎行与聚合')
                    .fontSize(12)
                    .lineHeight(17)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .margin({ top: 12 })
              .padding(14)
              .alignItems(VerticalAlign.Center)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .onClick(() => {
                this.pathStack.pushPath({ name: 'PluginServicesPage' });
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Text('凭证仅保存在本机 · 配置后自动参与聚合并发')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 2 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 30 + this.navBarH })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
