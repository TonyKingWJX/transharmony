import { settingsStore } from '../services/SettingsStore';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { OFFLINE_PROVIDER } from '../services/ProviderCatalog';
import { OFFLINE_PACK_ZH_EN, OfflineTranslator } from '../services/OfflineTranslator';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

/**
 * 离线翻译管理页（NavDestination 二级页，从「翻译服务」一级页进入）：
 *  - 总开关：启用/关闭离线翻译（关闭后引擎行与聚合模式均不出现离线引擎）
 *  - 已下载：内置「中英离线包」（行内开关 + 删除图标置灰——内置包不可删除）
 *  - 未下载：本期不做（预留：未来可下载语言包在此列出，含下载入口与删除）
 */

@Component
export struct OfflineTranslatePage {
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 沉浸式避让高度（vp）：全屏窗口下系统标题栏不避让状态栏，用自定义标题行 + 手动避让 */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 总开关与语言包开关的镜像态（aboutToAppear/onShown 时从存储刷新） */
  @State masterOn: boolean = false;
  @State packOn: boolean = true;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.masterOn = settingsStore.getOfflineEnabled();
    this.packOn = settingsStore.getOfflinePackEnabled();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 状态落盘后的公共收尾：重建引擎 + 广播引擎行刷新 */
  private applyChange(): void {
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 总开关：开启时视为已添加（从本页开启即明确表达启用意图，添加面板条目随之消失） */
  private async toggleMaster(on: boolean): Promise<void> {
    this.masterOn = on;
    await settingsStore.setOfflineEnabled(on);
    if (on && !settingsStore.getOfflineAdded()) {
      await settingsStore.setOfflineAdded(true);
    }
    this.applyChange();
    this.toast(on ? '已启用离线翻译，引擎行与聚合模式将使用端侧模型' : '已关闭离线翻译');
  }

  /** 语言包开关：仅停用/启用该包，不删除（内置包不可删除） */
  private async togglePack(on: boolean): Promise<void> {
    this.packOn = on;
    await settingsStore.setOfflinePackEnabled(on);
    this.applyChange();
    if (!on && this.masterOn) {
      this.toast('已停用中英离线包，离线翻译暂不可用');
    }
  }

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

          Text('离线翻译')
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
            // ── 总开关 ──
            Column() {
              Row({ space: 12 }) {
                Text(OFFLINE_PROVIDER.badge)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(40)
                  .height(40)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .linearGradient({ angle: 135, colors: [['#0BB36B', 0.0], ['#3ED598', 1.0]] })
                Column({ space: 3 }) {
                  Text('启用离线翻译')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('引擎行出现「离线翻译」，聚合模式参与并发')
                    .fontSize(11)
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.masterOn })
                  .width(40)
                  .height(24)
                  .selectedColor($r('app.color.brand'))
                  .onChange((on: boolean) => {
                    this.toggleMaster(on);
                  })
              }
              .width('100%')
              .padding(14)
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })

            // ── 已下载 ──
            Column() {
              Text('已下载')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
                .margin({ left: 4, bottom: 8 })

              Column() {
                // 内置中英双向语言包（单行：开关 + 置灰删除）
                Row({ space: 12 }) {
                  Text(OFFLINE_PROVIDER.badge)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Color.White)
                    .width(40)
                    .height(40)
                    .textAlign(TextAlign.Center)
                    .borderRadius(12)
                    .backgroundColor(OFFLINE_PROVIDER.color)
                  Column({ space: 4 }) {
                    Text(OFFLINE_PACK_ZH_EN.label)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.font_primary'))
                    Row({ space: 5 }) {
                      Circle()
                        .width(6)
                        .height(6)
                        .fill(this.packOn && this.masterOn
                          ? $r('app.color.confirm') : $r('app.color.font_fourth'))
                      Text(OFFLINE_PACK_ZH_EN.pair + ' · ' + OfflineTranslator.packSizeLabel()
                        + (this.packOn ? '' : ' · 已停用'))
                        .fontSize(11)
                        .fontColor(this.packOn && this.masterOn
                          ? $r('app.color.confirm') : $r('app.color.font_fourth'))
                    }
                    .alignItems(VerticalAlign.Center)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Toggle({ type: ToggleType.Switch, isOn: this.packOn })
                    .width(40)
                    .height(24)
                    .selectedColor($r('app.color.brand'))
                    .onChange((on: boolean) => {
                      this.togglePack(on);
                    })

                  // 内置包不可删除：图标置灰，点击仅提示
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(16)
                    .fontColor([$r('app.color.font_fourth')])
                    .opacity(0.4)
                    .padding(6)
                    .onClick(() => {
                      this.toast('内置语言包不可删除，可关闭开关停用');
                    })
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 11, bottom: 11 })
                .alignItems(VerticalAlign.Center)
                .opacity(this.masterOn ? 1 : 0.55)
              }
              .width('100%')
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .padding({ left: 12, right: 12, top: 4, bottom: 8 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // ── 未下载 ──
            // 预留：未来支持按需下载语言包（如中日/中韩）时在此列出，
            // 行内提供下载入口/进度/删除；本期仅内置中英包，板块整体隐藏。

            Text('语言包随应用内置，无需下载 · 翻译完全在本机完成，内容不出设备')
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
    .onShown(() => {
      this.refresh();
    })
  }
}
