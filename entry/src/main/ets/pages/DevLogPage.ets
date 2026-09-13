/**
 * 日志查看页（开发者模式三级页，NavDestination）：
 * 展示开发者日志系统采集的日志（新日志在上），经 AppStorage 版本号实时刷新；
 * 支持清空（内存 + 落盘）。导出入口在开发者模式页。
 * 沉浸式与自定义标题栏样式与其他 NavDestination 页保持一致。
 */

import { devLogStore, DevLogEntry, DEVLOG_VERSION_KEY } from '../services/DevLogStore';

@Component
export struct DevLogPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 采集数据版本号：DevLogStore 每次追加/清空后 bump，触发本页刷新 */
  @StorageProp(DEVLOG_VERSION_KEY) logVersion: number = 0;
  /** 渲染快照：版本号变化时从 DevLogStore 拉取 */
  @State entries: DevLogEntry[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    // 新日志在上
    this.entries = devLogStore.entries().slice().reverse();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 时间戳 → HH:mm:ss.mmm */
  private stampOf(ts: number): string {
    if (ts <= 0) {
      return '--:--:--';
    }
    const d = new Date(ts);
    const p = (n: number, w: number): string => String(n).padStart(w, '0');
    return p(d.getHours(), 2) + ':' + p(d.getMinutes(), 2) + ':' + p(d.getSeconds(), 2) + '.' + p(d.getMilliseconds(), 3);
  }

  /** 级别徽标配色：error 红 / warn 橙 / 其他品牌色 */
  private levelColor(level: string): Resource {
    if (level === 'error') {
      return $r('app.color.warning');
    }
    if (level === 'warn') {
      return $r('app.color.warning');
    }
    return $r('app.color.brand');
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

          Text('日志')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
          Text('清空')
            .fontSize(14)
            .fontColor($r('app.color.brand'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              devLogStore.clear();
              this.toast('已清空');
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        if (this.entries.length === 0) {
          // 空态
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.doc_text'))
              .fontSize(40)
              .fontColor([$r('app.color.font_fourth')])
            Text('暂无日志')
              .fontSize(13)
              .fontColor($r('app.color.font_tertiary'))
            Text('开启日志收集后，插件 $log 与关键事件会记录在这里')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8 }) {
            ForEach(this.entries, (e: DevLogEntry) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row({ space: 8 }) {
                    Text(e.level.toUpperCase())
                      .fontSize(9)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.levelColor(e.level))
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                      .borderRadius(999)
                      .border({ width: 0.8, color: this.levelColor(e.level) })
                    Text(e.tag)
                      .fontSize(10)
                      .fontColor($r('app.color.font_tertiary'))
                    Blank()
                    Text(this.stampOf(e.ts))
                      .fontSize(10)
                      .fontColor($r('app.color.font_tertiary'))
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  Text(e.message)
                    .fontSize(12)
                    .lineHeight(17)
                    .fontFamily('monospace')
                    .fontColor($r('app.color.font_secondary'))
                    .width('100%')
                    .copyOption(CopyOptions.LocalDevice)
                    .textAlign(TextAlign.Start)
                }
                .width('100%')
                .padding(12)
                .borderRadius(12)
                .backgroundColor($r('app.color.card_bg'))
                .border({ width: 0.8, color: $r('app.color.divider') })
                .alignItems(HorizontalAlign.Start)
              }
            }, (e: DevLogEntry) => e.ts + '-' + e.level + '-' + e.message)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 4, bottom: 30 + this.navBarH })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onShown(() => {
      this.reload();
    })
  }
}
