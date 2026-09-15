/**
 * 「语音服务TTS / 文字识别服务OCR」管理页（NavDestination，pageKind 路由注入，两页共用组件）：
 * - OCR（'ocr'）：传统 OCR（腾讯/百度）+ AI 视觉两组，添加面板列对应目录；
 * - TTS（'tts'）：语音合成单组，添加面板列 TTS_PROVIDERS（小米 MiMo/OpenAI/OpenAI 兼容/Anthropic 兼容）。
 * 行内 Toggle 开关、删除（二次确认）、组内长按拖动排序；点击行进入配置页（list 参数区分存储）。
 * 存储走 settingsStore 独立列表（tts_services_list / ocr_services_list），与翻译 services_list 完全隔离；
 * 增删改后 bump PILL_VERSION_KEY，偏好设置的 TTS/OCR 服务选择 Select 实时刷新。
 * 注意：添加面板刻意不用 bindSheet——同节点双 sheet + 嵌套 @Builder 参数在真机上事件分发不稳定
 * （官方文档：@Builder 多参数不支持内部 UI 刷新），与 BuiltinServicesPage 同款 Stack 叠层方案。
 */

import { settingsStore, ServiceItem } from '../services/SettingsStore';
import {
  findDef,
  ProviderDef,
  OCR_TRAD_PROVIDERS,
  OCR_AI_PROVIDERS,
  TTS_PROVIDERS
} from '../services/ProviderCatalog';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

@Component
export struct CloudServicesPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 页面类别：'ocr' | 'tts'（Index PageMap 注入） */
  @Prop pageKind: string = 'ocr';
  /** 沉浸式避让高度（vp）：全屏窗口下系统标题栏不避让状态栏，用自定义标题行 + 手动避让 */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 传统 OCR 分组（仅 OCR 页使用；TTS 页恒空） */
  @State tradItems: ServiceItem[] = [];
  /** AI 分组（OCR 的 AI 视觉 / TTS 的语音合成） */
  @State aiItems: ServiceItem[] = [];
  /** 添加面板（Stack 叠层）显示状态 */
  @State addPanelShow: boolean = false;
  /** 待删除的服务实例 */
  private deleteTarget: ServiceItem | null = null;

  aboutToAppear(): void {
    this.refresh();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private get navTitle(): string {
    return this.pageKind === 'ocr' ? '文字识别服务OCR' : '语音服务TTS';
  }

  /** 添加面板的传统分组目录（仅 OCR 页有传统服务商） */
  private tradCatalog(): ProviderDef[] {
    return this.pageKind === 'ocr' ? OCR_TRAD_PROVIDERS : [];
  }

  /** 添加面板的 AI 分组目录（OCR 的 AI 视觉 / TTS 的语音合成） */
  private aiCatalog(): ProviderDef[] {
    return this.pageKind === 'ocr' ? OCR_AI_PROVIDERS : TTS_PROVIDERS;
  }

  private refresh(): void {
    const all = this.pageKind === 'ocr' ? settingsStore.getOcrServices() : settingsStore.getTtsServices();
    const trad: ServiceItem[] = [];
    const ai: ServiceItem[] = [];
    for (const s of all) {
      const def = findDef(s.defId);
      if (this.pageKind === 'ocr' && def !== undefined && def.kind === 'ocr-trad') {
        trad.push(s);
      } else {
        ai.push(s);
      }
    }
    this.tradItems = trad;
    this.aiItems = ai;
  }

  /** 添加服务商：生成实例（id 取目录 id，重复时加序号），落盘到对应独立列表末尾 */
  private async addProvider(def: ProviderDef): Promise<void> {
    const list = settingsStore.getServiceList(this.pageKind);
    let id = def.id;
    if (list.some((s: ServiceItem): boolean => s.id === id)) {
      id = def.id + '-' + (list.length + 1).toString();
      while (list.some((s: ServiceItem): boolean => s.id === id)) {
        id = id + '-x';
      }
    }
    const item: ServiceItem = {
      id: id,
      defId: def.id,
      name: def.label,
      enabled: true,
      config: {}
    };
    list.push(item);
    await settingsStore.setServiceList(this.pageKind, list);
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    this.addPanelShow = false;
    this.toast('已添加 ' + def.label + '，请填写凭证');
    // 添加完直接进配置页填密钥（list 参数区分存储）
    const param: Record<string, string> = { 'serviceId': id, 'list': this.pageKind };
    this.pathStack.pushPath({ name: 'ServiceConfigPage', param: param });
  }

  private async toggle(s: ServiceItem, on: boolean): Promise<void> {
    const list = settingsStore.getServiceList(this.pageKind);
    const hit = list.find((it: ServiceItem): boolean => it.id === s.id);
    if (hit === undefined) {
      return;
    }
    hit.enabled = on;
    await settingsStore.setServiceList(this.pageKind, list);
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
  }

  /** 组内拖拽排序（List onMove 回调）：splice 对应分组数组（驱动落位动画）后按组序合并落盘 */
  private async moveGroup(isTrad: boolean, from: number, to: number): Promise<void> {
    const list = isTrad ? this.tradItems : this.aiItems;
    if (from < 0 || to < 0 || from === to || from >= list.length || to >= list.length) {
      return;
    }
    const moved = list.splice(from, 1);
    list.splice(to, 0, moved[0]);
    await settingsStore.setServiceList(this.pageKind, this.tradItems.concat(this.aiItems));
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 删除（AlertDialog 二次确认） */
  private confirmDelete(s: ServiceItem): void {
    this.deleteTarget = s;
    this.getUIContext().showAlertDialog({
      title: '删除服务商',
      message: '确定删除「' + s.name + '」？删除后其凭证配置将一并清除。',
      primaryButton: {
        value: '取消',
        action: (): void => {
          this.deleteTarget = null;
        }
      },
      secondaryButton: {
        value: '删除',
        style: DialogButtonStyle.HIGHLIGHT,
        action: (): void => {
          this.doDelete();
        }
      },
      cancel: (): void => {
        this.deleteTarget = null;
      }
    });
  }

  private async doDelete(): Promise<void> {
    if (this.deleteTarget === null) {
      return;
    }
    const id = this.deleteTarget.id;
    this.deleteTarget = null;
    await settingsStore.setServiceList(
      this.pageKind,
      settingsStore.getServiceList(this.pageKind).filter((s: ServiceItem): boolean => s.id !== id));
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    this.toast('已删除该服务商');
  }

  private openConfig(s: ServiceItem): void {
    const param: Record<string, string> = { 'serviceId': s.id, 'list': this.pageKind };
    this.pathStack.pushPath({ name: 'ServiceConfigPage', param: param });
  }

  /** 实例的目录定义 */
  private defOf(s: ServiceItem): ProviderDef | undefined {
    return findDef(s.defId);
  }

  private badgeColor(s: ServiceItem): string {
    const def = this.defOf(s);
    return def !== undefined ? def.color : '#0A9BFF';
  }

  private badgeText(s: ServiceItem): string {
    const def = this.defOf(s);
    return def !== undefined ? def.badge : '云';
  }

  /** 凭证是否已填齐（用于行内「未配置」提示） */
  private isReady(s: ServiceItem): boolean {
    const def = this.defOf(s);
    if (def === undefined) {
      return false;
    }
    for (const f of def.fields) {
      if (!f.optional && (s.config[f.key] ?? '').length === 0) {
        return false;
      }
    }
    return true;
  }

  /** 行内状态文案（含停用态） */
  private statusText(s: ServiceItem): string {
    if (!s.enabled) {
      return '已停用';
    }
    return this.isReady(s) ? '已配置' : '待填写凭证';
  }

  /** 行内状态色：绿=可用 / 橙=待配置 / 灰=停用 */
  private statusColor(s: ServiceItem): ResourceColor {
    if (!s.enabled) {
      return $r('app.color.font_fourth');
    }
    return this.isReady(s) ? $r('app.color.confirm') : $r('app.color.warning');
  }

  /** ForEach 键：拖拽重排时键值不变（仅顺序变化），保证 onMove 落位动画正常 */
  private serviceKey(s: ServiceItem): string {
    return s.id + (s.enabled ? '1' : '0') + s.name + (this.isReady(s) ? '1' : '0');
  }

  build() {
    NavDestination() {
      // Stack 叠层：内容层 + 添加面板层（同 BuiltinServicesPage，面板必须是内容层兄弟节点）
      Stack() {
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

            Text(this.navTitle)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Blank()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 12 })
          .alignItems(VerticalAlign.Center)

          Stack() {
            // ── 主内容层 ──
            Scroll() {
              Column({ space: 12 }) {
                Column({ space: 12 }) {
                  this.sectionLabel('已添加的服务商')

                  if (this.tradItems.length === 0 && this.aiItems.length === 0) {
                    // 空状态：引导添加
                    Column({ space: 8 }) {
                      Stack() {
                        Circle()
                          .width(48)
                          .height(48)
                          .fill($r('app.color.emphasize_bg_light'))
                        SymbolGlyph($r('sys.symbol.plus'))
                          .fontSize(20)
                          .fontColor([$r('app.color.brand')])
                      }
                      .width(48)
                      .height(48)

                      Text(this.pageKind === 'ocr' ? '还没有添加 OCR 服务商' : '还没有添加语音服务商')
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.font_secondary'))
                      Text('点击下方按钮，从目录中添加')
                        .fontSize(11)
                        .fontColor($r('app.color.font_fourth'))
                    }
                    .width('100%')
                    .padding({ top: 10, bottom: 16 })
                    .alignItems(HorizontalAlign.Center)
                    .borderRadius(16)
                    .backgroundColor($r('app.color.card_bg'))
                    .border({ width: 0.8, color: $r('app.color.divider') })
                  }
                  if (this.tradItems.length > 0) {
                    this.tradGroupCard()
                  }
                  if (this.aiItems.length > 0) {
                    this.aiGroupCard()
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)

                // ── 添加按钮 ──
                Button() {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.plus'))
                      .fontSize(16)
                      .fontColor([Color.White])
                    Text('添加服务商')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Color.White)
                  }
                  .alignItems(VerticalAlign.Center)
                }
                .width('100%')
                .height(44)
                .borderRadius(22)
                .backgroundColor($r('app.color.brand'))
                .onClick(() => {
                  this.addPanelShow = true;
                })

                Text('开关控制是否在偏好设置中可选 · 点击行配置凭证与模型')
                  .fontSize(11)
                  .fontColor($r('app.color.font_fourth'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 2 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 30 + this.navBarH })
            }
            .width('100%')
            .height('100%')
            .scrollable(ScrollDirection.Vertical)
            .align(Alignment.Top)
            .edgeEffect(EdgeEffect.Spring)
            .scrollBar(BarState.Off)
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 添加面板层（Stack 叠层；蒙层覆盖状态栏） ──
        if (this.addPanelShow) {
          Column() {
            // 点击空白区域收起
            Blank()
              .layoutWeight(1)
              .width('100%')
              .onClick(() => {
                this.addPanelShow = false;
              })

            // 底部卡片
            Column() {
              // 拖拽把手（半模态视觉惯例）
              Row()
                .width(36)
                .height(4)
                .borderRadius(2)
                .backgroundColor($r('app.color.divider'))
                .margin({ top: 8 })

              Row() {
                Text('添加服务商')
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.font_primary'))
                Blank()
                Text('完成')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.brand'))
                  .padding({ left: 10, right: 2, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.addPanelShow = false;
                  })
              }
              .width('100%')
              .padding({ left: 20, right: 16, top: 10, bottom: 4 })

              Scroll() {
                Column({ space: 4 }) {
                  if (this.tradCatalog().length > 0) {
                    this.sheetLabel(this.pageKind === 'ocr' ? '传统 OCR' : '传统服务商')
                    ForEach(this.tradCatalog(), (p: ProviderDef) => {
                      this.defRow(p)
                    }, (p: ProviderDef) => p.id)
                  }

                  this.sheetLabel(this.pageKind === 'ocr' ? 'AI 服务商（视觉模型）' : 'AI 语音合成')
                  ForEach(this.aiCatalog(), (p: ProviderDef) => {
                    this.defRow(p)
                  }, (p: ProviderDef) => p.id)

                  Text('添加后进入配置页填写凭证 · 凭证仅保存在本机')
                    .fontSize(11)
                    .fontColor($r('app.color.font_tertiary'))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 10 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 20 + this.navBarH })
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .constraintSize({ maxHeight: 460 })
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
            }
            .width('100%')
            .borderRadius({ topLeft: 24, topRight: 24 })
            .backgroundColor($r('app.color.card_bg'))
          }
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.40)')
          // 蒙层延伸到状态栏区，避免顶部出现未压暗的亮带
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
          .transition(TransitionEffect.OPACITY.animation({ duration: 180 })
            .combine(TransitionEffect.translate({ y: 40 })))
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
    .onShown(() => {
      // 从配置页返回时刷新（顺序/开关/删除/新添加都会落盘）
      this.refresh();
    })
  }

  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.font_secondary'))
      .letterSpacing(1)
      .width('100%')
      .margin({ left: 4, bottom: 8 })
  }

  /** 服务实例行：徽标 + 名称/状态 + 开关 + 删除；点击行主体进入配置，长按行拖动排序 */
  @Builder
  serviceRow(s: ServiceItem) {
    Row({ space: 12 }) {
      Text(this.badgeText(s))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(12)
        .backgroundColor(this.badgeColor(s))
      Column({ space: 4 }) {
        Text(s.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
        Row({ space: 5 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.statusColor(s))
          Text(this.statusText(s))
            .fontSize(11)
            .fontColor(this.statusColor(s))
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.openConfig(s);
      })

      // 启用开关（官方 Toggle）
      Toggle({ type: ToggleType.Switch, isOn: s.enabled })
        .width(40)
        .height(24)
        .selectedColor($r('app.color.brand'))
        .onChange((on: boolean) => {
          this.toggle(s, on);
        })

      // 删除
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(16)
        .fontColor([$r('app.color.font_fourth')])
        .padding(6)
        .onClick(() => {
          this.confirmDelete(s);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
  }

  /** 分组标题：左侧组名，右侧拖拽操作提示 */
  @Builder
  groupTitle(text: string) {
    Row() {
      Text(text)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_tertiary'))
        .letterSpacing(1)
      Blank()
      Text('长按拖动排序')
        .fontSize(10)
        .fontColor($r('app.color.font_fourth'))
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** 传统 OCR 分组卡片：List + ForEach.onMove（API 12+），长按行浮起拖动，离手播放落位动画 */
  @Builder
  tradGroupCard() {
    Column() {
      this.groupTitle(this.pageKind === 'ocr' ? '传统 OCR' : '传统服务商')
      List() {
        ForEach(this.tradItems, (s: ServiceItem) => {
          ListItem() {
            this.serviceRow(s)
          }
        }, (s: ServiceItem) => this.serviceKey(s))
          .onMove((from: number, to: number) => {
            this.moveGroup(true, from, to);
          })
      }
      .width('100%')
      .divider({ strokeWidth: 0.8, color: $r('app.color.divider'), startMargin: 64 })
      .scrollBar(BarState.Off)
      // 卡片内 List 高度自适应内容（外层 Scroll 负责整页滚动），关闭其自身滚动手势避免手势竞争
      .enableScrollInteraction(false)
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .margin({ bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /** AI 分组卡片（OCR 的 AI 视觉 / TTS 的语音合成；结构同传统分组） */
  @Builder
  aiGroupCard() {
    Column() {
      this.groupTitle(this.pageKind === 'ocr' ? 'AI 视觉' : 'AI 语音合成')
      List() {
        ForEach(this.aiItems, (s: ServiceItem) => {
          ListItem() {
            this.serviceRow(s)
          }
        }, (s: ServiceItem) => this.serviceKey(s))
          .onMove((from: number, to: number) => {
            this.moveGroup(false, from, to);
          })
      }
      .width('100%')
      .divider({ strokeWidth: 0.8, color: $r('app.color.divider'), startMargin: 64 })
      .scrollBar(BarState.Off)
      .enableScrollInteraction(false)
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .margin({ bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheetLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.font_secondary'))
      .letterSpacing(1)
      .width('100%')
      .margin({ top: 12, left: 4, bottom: 6 })
  }

  /** 目录行：点击添加（面板为 Stack 叠层普通组件，点击链路直连 addProvider） */
  @Builder
  defRow(p: ProviderDef) {
    Row({ space: 12 }) {
      Text(p.badge)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .borderRadius(12)
        .backgroundColor(p.color)
      Column({ space: 2 }) {
        Text(p.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
        Text(p.subtitle)
          .fontSize(11)
          .fontColor($r('app.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 添加入口：品牌色圆形热区
      Stack() {
        Circle()
          .width(28)
          .height(28)
          .fill($r('app.color.emphasize_bg_light'))
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(14)
          .fontColor([$r('app.color.brand')])
      }
      .width(28)
      .height(28)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .borderRadius(14)
    .backgroundColor($r('app.color.bg_container'))
    .margin({ bottom: 7 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.addProvider(p);
    })
  }
}
