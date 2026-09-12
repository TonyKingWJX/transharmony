/**
 * 首页：官方 Navigation 容器承载路由，首页内容为 Stack 悬浮胶囊页签。
 * 页签对齐鸿蒙官方设计规范（design-guides「底部页签·悬浮式」）：
 * 胶囊容器 248×56vp（3 页签固定宽）、沉浸光感模糊材质、页签文字 2 字、
 * 未选中置灰弱化、底部避让系统手势导航条。
 * 三个子页常驻挂载（visibility 切换），保留各自的输入/滚动状态；
 * 二级页（翻译服务系列）通过 NavDestination 官方标题栏承载（自动返回箭头）。
 */

import { TranslatePageContent } from './TranslatePage';
import { HistoryPageContent } from './HistoryPage';
import { SettingsPageContent } from './SettingsPage';
import { ServicesPage } from './ServicesPage';
import { BuiltinServicesPage } from './BuiltinServicesPage';
import { OfflineTranslatePage } from './OfflineTranslatePage';
import { ServiceConfigPage } from './ServiceConfigPage';
import { PrivacyPage, AboutPage, FeedbackPage } from './AboutPage';
import { ImageTranslatePage, ImageTransParam } from './ImageTranslatePage';
import { HistoryDetailPage, HistoryDetailParam } from './HistoryDetailPage';
import { PluginLabPage } from './PluginLabPage';
import { PluginServicesPage } from './PluginServicesPage';
import { PluginConfigPage } from './PluginConfigPage';
import { HISTORY_VERSION_KEY } from '../services/HistoryStore';

/** 路由表：navDestination 要求 @Builder 函数引用（官方约束，不能用行内 lambda） */
@Builder
function PageMap(name: string, param: object) {
  if (name === 'ServicesPage') {
    ServicesPage()
  } else if (name === 'BuiltinServicesPage') {
    BuiltinServicesPage()
  } else if (name === 'OfflineTranslatePage') {
    OfflineTranslatePage()
  } else if (name === 'ServiceConfigPage') {
    ServiceConfigPage({ serviceId: (param as Record<string, string>)['serviceId'] })
  } else if (name === 'PrivacyPage') {
    PrivacyPage()
  } else if (name === 'AboutPage') {
    AboutPage()
  } else if (name === 'FeedbackPage') {
    FeedbackPage()
  } else if (name === 'ImageTranslatePage') {
    ImageTranslatePage({ session: param as ImageTransParam })
  } else if (name === 'HistoryDetailPage') {
    HistoryDetailPage({ recordId: (param as HistoryDetailParam).id })
  } else if (name === 'PluginLabPage') {
    // TODO(spike) 插件实验室调试页：JSVM spike 验证完成后连同入口一起移除
    PluginLabPage()
  } else if (name === 'PluginServicesPage') {
    PluginServicesPage()
  } else if (name === 'PluginConfigPage') {
    PluginConfigPage({ pluginId: (param as Record<string, string>)['pluginId'] })
  }
}

@Entry
@Component
struct Index {
  @Provide('navPathStack') pathStack: NavPathStack = new NavPathStack();
  @State currentIndex: number = 0;
  /** 历史页多选/回收站子模式：隐藏底部胶囊页签与渐隐蒙版，返回键拦截退出子模式而非应用 */
  @State historySubmode: boolean = false;
  /** 返回键命令计数：onBackPress 拦截后递增，经 @Param 桥接给 V2 历史页（@Monitor 响应） */
  @State historyBackCmd: number = 0;
  /** 沉浸式避让高度（vp），由 Ux 写入 AppStorage */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 窗口宽度（vp）：平板宽屏断点依据，Ux 写入 AppStorage */
  @StorageProp('ux_winW') winW: number = 0;
  /** 历史数据版本号：HistoryStore 每次写操作后 bump，桥接给 V2 历史页实时刷新 */
  @StorageProp(HISTORY_VERSION_KEY) historyVersion: number = 0;

  /** 页签图标：选中态用 fill 变体（官方底部页签规范） */
  private readonly TAB_ICONS: [Resource, Resource][] = [
    [$r('sys.symbol.house'), $r('sys.symbol.house_fill')],
    [$r('sys.symbol.clock'), $r('sys.symbol.clock_fill')],
    [$r('sys.symbol.person_crop_circle_fill'), $r('sys.symbol.person_crop_circle_fill')]
  ];
  private readonly TAB_LABELS: string[] = ['翻译', '历史', '我的'];

  /** 系统返回键：历史页多选/回收站态时拦截，通知历史页退出子模式而非退出应用 */
  onBackPress(): boolean {
    if (this.historySubmode) {
      this.historyBackCmd = Date.now();
      return true;
    }
    return false;
  }

  @Builder
  tabItem(index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.TAB_ICONS[index][this.currentIndex === index ? 1 : 0])
        .fontSize(21)
        .fontColor([this.currentIndex === index ? $r('app.color.brand') : $r('app.color.font_tertiary')])
      Text(this.TAB_LABELS[index])
        .fontSize(10)
        .letterSpacing(1)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? $r('app.color.brand') : $r('app.color.font_tertiary'))
    }
    .width(82)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      // 页签切换：官方底部页签内容区为无动画即切。整页转场（含位移/透明度）
      // 在真机上均出现抽搐/角落飞入，改为一刀切：不做任何页面级过渡。
      this.currentIndex = index;
    })
  }

  build() {
    Navigation(this.pathStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 内容层：三个子页常驻，visibility 切换保状态。
        // 翻译页不在包裹层做状态栏避让（padding 会把蒙层边界推离避让区，
        // 导致面板蒙层 expandSafeArea 失效、状态栏露出亮带），由页内 header 自行避让。
        Column() {
          TranslatePageContent({ currentIndex: this.currentIndex })
        }
        .width('100%')
        .height('100%')
        .visibility(this.currentIndex === 0 ? Visibility.Visible : Visibility.None)

        Column() {
          HistoryPageContent({
            currentIndex: this.currentIndex,
            navBarH: this.navBarH,
            winW: this.winW,
            historyVersion: this.historyVersion,
            onOpenDetail: (id: number): void => {
              this.pathStack.pushPath({ name: 'HistoryDetailPage', param: { id: id } as HistoryDetailParam });
            },
            onSubmodeChange: (active: boolean): void => {
              this.historySubmode = active;
            },
            backCmd: this.historyBackCmd
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.statusBarH })
        .visibility(this.currentIndex === 1 ? Visibility.Visible : Visibility.None)

        Column() {
          SettingsPageContent({ currentIndex: this.currentIndex })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.statusBarH })
        .visibility(this.currentIndex === 2 ? Visibility.Visible : Visibility.None)

        // 底部渐隐蒙版：透明 → 页面底色。列表内容滚入胶囊区域时自然淡出，
        // 避免被不透明胶囊「生硬切割」。高度对齐官方规范（design-guides「底部页签」：
        // 渐变层顶边较页签最顶边高 16vp）＝ 56 胶囊 + 12 边距 + 导航条 + 16；
        // 此前写死 180，静止时最后一张卡片会被整张罩进渐变区。
        // 渐变起点是全透明，空内容时该层不可见。
        // 写法注意：Column 内必须有真实子节点且高度用固定值（Blank+layoutWeight
        // 在无约束容器里高度塌陷，之前蒙版因此没有渲染出来）。
        // 各滚动容器底部 padding 需 ≥ 本层高度（见 HistoryPage / TranslatePage）。
        Column() {
          Row()
            .width('100%')
            .height(1)
        }
        .width('100%')
        .height(84 + this.navBarH)
        .align(Alignment.Bottom)
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.fade_from'), 0.0],
            [$r('app.color.bg_page'), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
        // 历史页多选/回收站态：隐藏蒙版，把列表空间全部让出来
        .visibility(this.historySubmode ? Visibility.None : Visibility.Visible)

        // 悬浮胶囊页签：248×56vp，不透明底色 + 投影。
        // 不用 backgroundBlurStyle：模糊材质在部分设备上的取样/扩散区域大于组件本身，
        // 会在页签正后方渲染出一条与页面底色不同的灰蓝色带（真机/模拟器可见）。
        Row() {
          this.tabItem(0)
          this.tabItem(1)
          this.tabItem(2)
        }
        .width(248)
        .height(56)
        .borderRadius(28)
        .backgroundColor($r('app.color.card_bg'))
        .border({ width: 0.8, color: $r('app.color.divider') })
        .shadow({ radius: 24, color: 'rgba(0,0,0,0.14)', offsetY: 6 })
        .margin({ bottom: this.navBarH + 12 })
        .clip(true)
        // 历史页多选/回收站态：隐藏胶囊页签（返回键退出子模式，见 onBackPress）
        .visibility(this.historySubmode ? Visibility.None : Visibility.Visible)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
    }
    .navDestination(PageMap)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}
