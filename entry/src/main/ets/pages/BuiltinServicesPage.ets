/**
 * 「翻译服务」页（NavDestination）：
 * 上半：免费服务商分组（仅展示已添加的；默认关闭，需在「添加服务商」面板手动添加；
 *       行内 Toggle 开关、删除（二次确认）、组内长按拖动排序，顺序传导到聚合并发顺序与引擎 chip 默认顺序）
 * 下半：已配置的服务商列表——按「传统翻译 / AI 翻译」分组展示（存储顺序已按此归并），
 *       组内长按行拖动排序（List + ForEach.onMove）；行内：Toggle 开关、删除（AlertDialog 二次确认）；点击行进入配置页。
 * 「添加服务商」按钮：Stack 叠层弹出底部面板（免费服务商 + 传统 8 家 + AI 预置/兼容格式），
 *       免费服务商单实例：未添加的才列出，点击即添加；用户服务商点击任一行即添加并跳转配置页。蒙层点击收起。
 * 沉浸式：蒙层 expandSafeArea 延伸到状态栏，避免「顶部一条亮带」。
 * 注意：添加面板刻意不用 bindSheet——同节点双 sheet + 嵌套 @Builder 参数
 * 在真机上事件分发不稳定（官方文档：@Builder 多参数不支持内部 UI 刷新）。
 */

import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { EngineRegistry } from '../services/EngineRegistry';
import { findDef, FREE_PROVIDERS, TRAD_PROVIDERS, AI_PROVIDERS, ProviderDef } from '../services/ProviderCatalog';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

@Component
export struct BuiltinServicesPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 沉浸式避让高度（vp）：全屏窗口下系统标题栏不避让状态栏，用自定义标题行 + 手动避让 */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 传统翻译分组（存储顺序已按「传统在前、AI 在后」归并，组内顺序即展示顺序） */
  @State tradServices: ServiceItem[] = [];
  /** AI 翻译分组 */
  @State aiServices: ServiceItem[] = [];
  /** 内置免费通道（顺序 = 存储 builtin_order，组内可拖拽排序） */
  @State freeItems: ProviderDef[] = [];
  /** 添加面板的免费服务商候选：未添加的才列出（单实例） */
  @State freePending: ProviderDef[] = [];
  /** 添加面板（Stack 叠层）显示状态 */
  @State addPanelShow: boolean = false;
  /** 待删除的服务实例 */
  private deleteTarget: ServiceItem | null = null;
  /** 待删除的内置免费通道 id */
  private builtinDeleteId: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private refresh(): void {
    const all = settingsStore.getServices();
    const trad: ServiceItem[] = [];
    const ai: ServiceItem[] = [];
    for (const s of all) {
      // Bob 插件实例在「插件服务」页管理，不进内置服务分组
      if (s.defId.startsWith('plugin:')) {
        continue;
      }
      const def = findDef(s.defId);
      if (def !== undefined && def.kind === 'trad') {
        trad.push(s);
      } else {
        ai.push(s);
      }
    }
    this.tradServices = trad;
    this.aiServices = ai;
    // 免费服务商分组：仅展示已添加的（含停用态），顺序按存储
    const free: ProviderDef[] = [];
    for (const id of settingsStore.getBuiltinOrder()) {
      if (!settingsStore.isBuiltinAdded(id)) {
        continue;
      }
      const def = findDef(id);
      if (def !== undefined) {
        free.push(def);
      }
    }
    this.freeItems = free;
    // 添加面板候选：未生效的免费服务商（未添加，或已添加但停用——停用态显示「启用」可恢复）
    const pending: ProviderDef[] = [];
    for (const p of FREE_PROVIDERS) {
      if (!settingsStore.isBuiltinActive(p.id)) {
        pending.push(p);
      }
    }
    this.freePending = pending;
  }

  /** 添加服务商：生成实例（id 取目录 id，重复时加序号），落盘时归并到所属分组末尾 */
  private async addProvider(def: ProviderDef): Promise<void> {
    // 免费服务商单实例，不走服务实例化（由添加面板的免费分组单独处理）
    if (EngineRegistry.isBuiltin(def.id)) {
      return;
    }
    const list = settingsStore.getServices();
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
    await settingsStore.setServices(list);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    this.addPanelShow = false;
    this.toast('已添加 ' + def.label + '，请填写凭证');
    // 添加完直接进配置页填密钥
    const param: Record<string, string> = { 'serviceId': id };
    this.pathStack.pushPath({ name: 'ServiceConfigPage', param: param });
  }

  private async toggle(s: ServiceItem, on: boolean): Promise<void> {
    await settingsStore.setServiceEnabled(s.id, on);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
  }

  /** 添加/启用免费服务商（单实例）：未添加=写入已添加+启用；已添加但停用=仅重新启用 */
  private async enableFreeProvider(p: ProviderDef): Promise<void> {
    const added = settingsStore.getBuiltinAdded();
    const already = added.includes(p.id);
    if (!already) {
      added.push(p.id);
      await settingsStore.setBuiltinAdded(added);
    }
    const enabled = settingsStore.getBuiltinEnabled();
    if (!enabled.includes(p.id)) {
      enabled.push(p.id);
      await settingsStore.setBuiltinEnabled(enabled);
    }
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    this.toast((already ? '已启用 ' : '已添加 ') + p.label + '，可在翻译页引擎行使用');
  }

  /** 组内拖拽排序（List onMove 回调）：只 splice 对应分组数组（驱动落位动画），
   *  随后按「传统在前、AI 在后」合并落盘；不调用 refresh()（整组重建会打断落位动画） */
  private async moveGroup(isTrad: boolean, from: number, to: number): Promise<void> {
    const list = isTrad ? this.tradServices : this.aiServices;
    if (from < 0 || to < 0 || from === to || from >= list.length || to >= list.length) {
      return;
    }
    const moved = list.splice(from, 1);
    list.splice(to, 0, moved[0]);
    await settingsStore.setServices(this.tradServices.concat(this.aiServices));
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 内置免费通道排序（List onMove）：splice 驱动落位动画，顺序落盘 builtin_order */
  private async moveFree(from: number, to: number): Promise<void> {
    if (from < 0 || to < 0 || from === to || from >= this.freeItems.length || to >= this.freeItems.length) {
      return;
    }
    const moved = this.freeItems.splice(from, 1);
    this.freeItems.splice(to, 0, moved[0]);
    const ids: string[] = [];
    for (const p of this.freeItems) {
      ids.push(p.id);
    }
    await settingsStore.setBuiltinOrder(ids);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 内置免费服务商开关：启用才进引擎行/聚合（默认关闭） */
  private async toggleFree(id: string, on: boolean): Promise<void> {
    const enabled = settingsStore.getBuiltinEnabled();
    const idx = enabled.indexOf(id);
    if (on && idx < 0) {
      enabled.push(id);
    } else if (!on && idx >= 0) {
      enabled.splice(idx, 1);
    }
    await settingsStore.setBuiltinEnabled(enabled);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    const def = findDef(id);
    this.toast((def !== undefined ? def.label : id) + (on ? ' 已启用' : ' 已停用'));
  }

  /** 删除免费服务商（AlertDialog 二次确认）：从已添加中移除，可在「添加服务商」重新添加 */
  private confirmDeleteFree(p: ProviderDef): void {
    this.builtinDeleteId = p.id;
    this.getUIContext().showAlertDialog({
      title: '删除免费服务商',
      message: '确定删除「' + p.label + '」？删除后将不再出现在引擎选择行，可在「添加服务商」中重新添加。',
      primaryButton: {
        value: '取消',
        action: (): void => {
          this.builtinDeleteId = '';
        }
      },
      secondaryButton: {
        value: '删除',
        style: DialogButtonStyle.HIGHLIGHT,
        action: (): void => {
          this.doDeleteFree();
        }
      },
      cancel: (): void => {
        this.builtinDeleteId = '';
      }
    });
  }

  private async doDeleteFree(): Promise<void> {
    const id = this.builtinDeleteId;
    this.builtinDeleteId = '';
    if (id.length === 0) {
      return;
    }
    await settingsStore.setBuiltinAdded(
      settingsStore.getBuiltinAdded().filter((e: string): boolean => e !== id));
    await settingsStore.setBuiltinEnabled(
      settingsStore.getBuiltinEnabled().filter((e: string): boolean => e !== id));
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.refresh();
    this.toast('已删除该免费服务商，可在「添加服务商」中重新添加');
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
    await settingsStore.removeService(this.deleteTarget.id);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.deleteTarget = null;
    this.refresh();
    this.toast('已删除该服务商');
  }

  private openConfig(s: ServiceItem): void {
    const param: Record<string, string> = { 'serviceId': s.id };
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
    return def !== undefined ? def.badge : '译';
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
      // Stack 叠层：内容层 + 添加面板层。面板必须是内容层的兄弟节点——
      // 之前放在 Column 主轴尾部，height('100%') 会把 layoutWeight(1) 的
      // 内容区压缩为 0（表现为「背景全黑」），且蒙层无法盖住内容层。
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

          Text('翻译服务')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Stack() {
          // ── 主内容层 ──
          Scroll() {
            Column({ space: 12 }) {
              // ── 已配置的服务商（免费服务商 + 用户添加，均可开关/删除/组内排序） ──
              Column({ space: 12 }) {
                this.sectionLabel('已配置的服务商')

                // 免费服务商（已添加的；行内开关/删除，组内长按拖拽排序）
                if (this.freeItems.length > 0) {
                  Column() {
                    this.groupTitle('免费服务商')
                    List() {
                      ForEach(this.freeItems, (p: ProviderDef) => {
                        ListItem() {
                          this.freeRow(p)
                        }
                      }, (p: ProviderDef) => p.id + (settingsStore.isBuiltinEnabled(p.id) ? '_on' : '_off'))
                        .onMove((from: number, to: number) => {
                          this.moveFree(from, to);
                        })
                    }
                    .width('100%')
                    .divider({ strokeWidth: 0.8, color: $r('app.color.divider'), startMargin: 64 })
                    .scrollBar(BarState.Off)
                    // 卡片内 List 高度自适应内容（外层 Scroll 负责整页滚动），关闭其自身滚动手势避免手势竞争
                    .enableScrollInteraction(false)

                    Text('长按行拖动排序；点删除图标移除，可在「添加服务商」中重新添加')
                      .fontSize(10)
                      .fontColor($r('app.color.font_fourth'))
                      .width('100%')
                      .padding({ left: 4, right: 4, top: 6 })
                  }
                  .width('100%')
                  .borderRadius(16)
                  .backgroundColor($r('app.color.card_bg'))
                  .border({ width: 0.8, color: $r('app.color.divider') })
                  .padding({ left: 12, right: 12, top: 4, bottom: 8 })
                  .alignItems(HorizontalAlign.Start)
                }

                if (this.tradServices.length === 0 && this.aiServices.length === 0 && this.freeItems.length === 0) {
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

                    Text('还没有添加服务商')
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
                if (this.tradServices.length > 0) {
                  this.tradGroupCard()
                }
                if (this.aiServices.length > 0) {
                  this.aiGroupCard()
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)

              // ── 添加按钮（官方 Button + Symbol 前缀图标） ──
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

              Text('开关控制是否参与聚合并发与引擎选择 · 组内顺序即聚合返回顺序')
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
                  // 免费服务商：单实例，未添加的才列出，全部添加后分组不显示
                  if (this.freePending.length > 0) {
                    this.sheetLabel('免费服务商')
                    ForEach(this.freePending, (p: ProviderDef) => {
                      this.freeAddRow(p)
                    }, (p: ProviderDef) => p.id)
                  }

                  this.sheetLabel('传统机器翻译')
                  ForEach(TRAD_PROVIDERS, (p: ProviderDef) => {
                    this.defRow(p)
                  }, (p: ProviderDef) => p.id)

                  this.sheetLabel('AI 翻译')
                  ForEach(AI_PROVIDERS, (p: ProviderDef) => {
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

  /** 内置免费通道行：徽标 + 名称/状态 + 开关 + 删除；长按行拖动排序 */
  @Builder
  freeRow(p: ProviderDef) {
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
      Column({ space: 4 }) {
        Text(p.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
        Row({ space: 5 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(settingsStore.isBuiltinEnabled(p.id)
              ? $r('app.color.confirm') : $r('app.color.font_fourth'))
          Text(settingsStore.isBuiltinEnabled(p.id) ? '已启用' : '已停用')
            .fontSize(11)
            .fontColor(settingsStore.isBuiltinEnabled(p.id)
              ? $r('app.color.confirm') : $r('app.color.font_fourth'))
        }
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 启用开关（官方 Toggle，默认关闭）
      Toggle({ type: ToggleType.Switch, isOn: settingsStore.isBuiltinEnabled(p.id) })
        .width(40)
        .height(24)
        .selectedColor($r('app.color.brand'))
        .onChange((on: boolean) => {
          this.toggleFree(p.id, on);
        })

      // 删除
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(16)
        .fontColor([$r('app.color.font_fourth')])
        .padding(6)
        .onClick(() => {
          this.confirmDeleteFree(p);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
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

  /** 传统翻译分组卡片：List + ForEach.onMove（API 12+），长按行浮起拖动，离手播放落位动画 */
  @Builder
  tradGroupCard() {
    Column() {
      this.groupTitle('传统翻译')
      List() {
        ForEach(this.tradServices, (s: ServiceItem) => {
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

  /** AI 翻译分组卡片（结构同传统翻译组） */
  @Builder
  aiGroupCard() {
    Column() {
      this.groupTitle('AI 翻译')
      List() {
        ForEach(this.aiServices, (s: ServiceItem) => {
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

  /** 免费服务商候选行：单实例，点击即添加/启用（无凭证，不跳配置页）；按钮按状态显示「添加/启用」 */
  @Builder
  freeAddRow(p: ProviderDef) {
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

      // 状态按钮：品牌色胶囊（与翻译页添加面板同款语义）
      Text(settingsStore.isBuiltinAdded(p.id) ? '启用' : '添加')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.brand'))
        .borderRadius(999)
        .padding({ left: 13, right: 13, top: 6, bottom: 6 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .borderRadius(14)
    .backgroundColor($r('app.color.bg_container'))
    .margin({ bottom: 7 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.enableFreeProvider(p);
    })
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
