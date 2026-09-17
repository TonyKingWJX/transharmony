/**
 * 开发者模式二级页（NavDestination）：
 * 入口：关于鸿译 → 连点应用信息卡 5 次 → 确认弹窗 → 开发者模式行。
 * - 插件实验室：JSVM/插件调试页入口（原设置页入口已移入此处）
 * - 日志系统：日志收集开关（关闭即停采并清空）、查看日志、导出日志（DocumentViewPicker 保存本地）
 * 开发者模式关闭（关于页开关）后本页入口隐藏，日志收集同步关闭。
 * 沉浸式与自定义标题栏样式与其他 NavDestination 页保持一致。
 */

import { devLogStore } from '../services/DevLogStore';
import { common } from '@kit.AbilityKit';

@Component
export struct DeveloperPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 日志收集开关状态（devLogStore 持久化到 Preferences） */
  @State logEnabled: boolean = false;
  /** 导出中 */
  @State exporting: boolean = false;

  aboutToAppear(): void {
    this.logEnabled = devLogStore.getEnabled();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 日志收集开关：关闭即停采并清空（内存 + 落盘） */
  private onLogToggle(on: boolean): void {
    this.logEnabled = on;
    devLogStore.setEnabled(on);
    this.toast(on ? '已开启日志收集' : '已关闭日志收集');
  }

  /** 导出日志：系统文件管理器选择位置保存（取消则不导出） */
  private async exportLog(): Promise<void> {
    if (this.exporting) {
      return;
    }
    if (devLogStore.entries().length === 0) {
      this.toast('暂无日志可导出');
      return;
    }
    this.exporting = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fileName = await devLogStore.exportLog(ctx);
      this.toast(fileName.length > 0 ? '已导出：' + fileName : '已取消导出');
    } catch (e) {
      this.toast('导出失败：' + ((e instanceof Error) ? e.message : String(e)));
    } finally {
      this.exporting = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        Blank().height(this.statusBarH)

        // 自定义标题栏
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

          Text('开发者模式')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 14 }) {
            // ── 插件实验室 ──
            Column() {
              Row({ space: 12 }) {
                Column({ space: 3 }) {
                  Text('插件实验室')
                    .fontSize(15)
                    .fontColor($r('app.color.font_primary'))
                  Text('JSVM 连通性、ESM 探针、插件安装管线调试')
                    .fontSize(11)
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.pathStack.pushPath({ name: 'PluginLabPage' });
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })

            // ── 日志系统 ──
            Column() {
              Row({ space: 12 }) {
                Column({ space: 3 }) {
                  Text('日志收集')
                    .fontSize(15)
                    .fontColor($r('app.color.font_primary'))
                  Text('采集插件 $log 与关键事件，关闭即停采并清空')
                    .fontSize(11)
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.logEnabled })
                  .width(40)
                  .height(24)
                  .selectedColor($r('app.color.brand'))
                  .onChange((on: boolean) => {
                    this.onLogToggle(on);
                  })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(VerticalAlign.Center)

              Divider().color($r('app.color.divider')).strokeWidth(0.8)

              Row({ space: 12 }) {
                Text('查看日志')
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                Blank()
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.pathStack.pushPath({ name: 'DevLogPage' });
              })

              Divider().color($r('app.color.divider')).strokeWidth(0.8)

              Row({ space: 12 }) {
                if (this.exporting) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color($r('app.color.brand'))
                }
                Text('导出日志')
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                Blank()
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(16)
                  .fontColor([$r('app.color.font_fourth')])
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.exportLog();
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })

            Text('开发者功能仅供开发调试使用，关闭开发者模式后日志收集同步关闭')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ bottom: 30 + this.navBarH })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
