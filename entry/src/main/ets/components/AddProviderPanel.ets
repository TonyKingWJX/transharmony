/**
 * 添加服务商面板：bindSheet 半模态的纯内容组件（蒙层/圆角/拖拽条由 bindSheet 提供）。
 * 列出传统机器翻译与 AI 翻译服务商，点击行为按当前状态分流：
 * 已添加仅提示 / 启用已有实例 / 跳配置页 / 新建实例并跳配置页。
 * 翻译主页与图片翻译页共用；关闭由宿主 onClose 控制，跳配置页经 onOpenConfig 回调注入
 * （bindSheet 的 builder 挂在页面级 overlay 上，不保证继承宿主 @Consume 上下文，故不直接拿路由栈）。
 */

import { TranslateUseCase } from '../services/TranslateUseCase';
import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { FREE_PROVIDERS, TRAD_PROVIDERS, AI_PROVIDERS, OFFLINE_PROVIDER, ProviderDef } from '../services/ProviderCatalog';
import { OFFLINE_FEATURE_ENABLED } from '../services/OfflineTranslator';
import { PILL_VERSION_KEY } from './EngineSelector';

@Component
export struct AddProviderPanel {
  /** 请求关闭面板（完成按钮/启用成功后；蒙层与返回键由 bindSheet 默认行为处理） */
  onClose: () => void = (): void => {};
  /** 跳转服务商配置页（宿主注入 Navigation 路由栈操作） */
  onOpenConfig: (serviceId: string) => void = (_serviceId: string): void => {
  };
  /** 免费服务商候选：未生效的才列出（未添加，或已添加但停用——停用态显示「启用」可直接恢复） */
  @State freePending: ProviderDef[] = [];
  /** 离线翻译是否待生效（未添加或总开关关闭；生效后分区消失） */
  @State offlinePending: boolean = false;
  /** 服务列表变更版本号：chip × 停用/管理页开关后重新计算候选清单 */
  @StorageProp(PILL_VERSION_KEY) @Watch('refreshPending') pillVersion: number = 0;

  aboutToAppear(): void {
    this.refreshPending();
  }

  private refreshPending(): void {
    const pending: ProviderDef[] = [];
    for (const p of FREE_PROVIDERS) {
      if (!settingsStore.isBuiltinActive(p.id)) {
        pending.push(p);
      }
    }
    this.freePending = pending;
    // 引擎接入前总闸关闭：面板不出现离线翻译分区
    this.offlinePending = OFFLINE_FEATURE_ENABLED
      && (!settingsStore.getOfflineAdded() || !settingsStore.getOfflineEnabled());
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private bumpPill(): void {
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 添加/启用免费服务商（单实例）：未添加=写入已添加+启用；已添加但停用=仅重新启用（chip × 后可在此恢复） */
  private async addFree(p: ProviderDef): Promise<void> {
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
    this.bumpPill();
    const idx = this.freePending.findIndex((f: ProviderDef): boolean => f.id === p.id);
    if (idx >= 0) {
      this.freePending.splice(idx, 1);
    }
    this.toast((already ? '已启用 ' : '已添加 ') + p.label + '，可在引擎行使用');
  }

  /** 添加/启用离线翻译（单实例）：未添加=写入已添加+开总开关；已添加但总开关关=仅重开总开关 */
  private async addOffline(): Promise<void> {
    const already = settingsStore.getOfflineAdded();
    if (!already) {
      await settingsStore.setOfflineAdded(true);
    }
    await settingsStore.setOfflineEnabled(true);
    TranslateUseCase.refreshServices();
    this.bumpPill();
    this.offlinePending = false;
    this.toast((already ? '已启用 ' : '已添加 ') + OFFLINE_PROVIDER.label + '，可在引擎行使用');
  }

  /** 某服务商在添加面板中的状态：added=已显示 / enable=可启用 / config=待配置 / add=待添加 */
  private providerStatus(def: ProviderDef): string {
    const instances = settingsStore.getServices().filter((s: ServiceItem): boolean => s.defId === def.id);
    if (instances.length > 0) {
      for (const s of instances) {
        if (s.enabled && TranslateUseCase.isConfigured(s.id)) {
          return 'added';
        }
      }
      for (const s of instances) {
        if (TranslateUseCase.isConfigured(s.id)) {
          return 'enable';
        }
      }
      return 'config';
    }
    return 'add';
  }

  private statusLabel(st: string): string {
    if (st === 'added') {
      return '已添加';
    }
    if (st === 'enable') {
      return '启用';
    }
    if (st === 'config') {
      return '去配置';
    }
    return '添加';
  }

  /** 添加面板点击服务商：按状态直接启用 / 跳配置页 / 新建实例并跳配置页 */
  private async handleProviderTap(def: ProviderDef): Promise<void> {
    const st = this.providerStatus(def);
    const instances = settingsStore.getServices().filter((s: ServiceItem): boolean => s.defId === def.id);
    if (st === 'added') {
      this.toast(def.label + ' 已在引擎选择中');
      return;
    }
    if (st === 'enable') {
      for (const s of instances) {
        if (TranslateUseCase.isConfigured(s.id)) {
          await settingsStore.setServiceEnabled(s.id, true);
          break;
        }
      }
      TranslateUseCase.refreshServices();
      this.bumpPill();
      this.onClose();
      this.toast('已启用 ' + def.label);
      return;
    }
    this.onClose();
    if (st === 'config') {
      for (const s of instances) {
        if (!TranslateUseCase.isConfigured(s.id)) {
          this.onOpenConfig(s.id);
          return;
        }
      }
      return;
    }
    // add：新建实例并跳转配置页（未配置前不会出现在引擎行）
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
    this.bumpPill();
    this.onOpenConfig(id);
  }

  build() {
    // bindSheet 半模态内容：模态蒙层/顶部圆角/拖拽条/安全区避让均由 bindSheet 提供
    Column() {
      Row() {
        Text('添加服务商')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
        Blank()
        // 关闭按钮：文字按钮，带充足热区
        Text('完成')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.brand'))
          .padding({ left: 10, right: 2, top: 8, bottom: 8 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 10, bottom: 4 })

      Scroll() {
        Column({ space: 4 }) {
          // 免费服务商：单实例，未添加的才列出，全部添加后分组整个不显示
          if (this.freePending.length > 0) {
            this.panelLabel('免费服务商')
            ForEach(this.freePending, (p: ProviderDef) => {
              this.freeAddRow(p)
            }, (p: ProviderDef) => p.id)
          }

          // 离线翻译：端侧内置模型，未添加时显示（添加动作 = 加入引擎行并开总开关）
          if (this.offlinePending) {
            this.panelLabel('离线翻译')
            this.freeAddRow(OFFLINE_PROVIDER)
          }

          this.panelLabel('传统机器翻译')
          ForEach(TRAD_PROVIDERS, (p: ProviderDef) => {
            this.providerRow(p)
          }, (p: ProviderDef) => p.id)

          this.panelLabel('AI 翻译')
          ForEach(AI_PROVIDERS, (p: ProviderDef) => {
            this.providerRow(p)
          }, (p: ProviderDef) => p.id)

          Text('添加后进入配置页填写凭证 · 凭证仅保存在本机')
            .fontSize(11)
            .fontColor($r('app.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 460 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    // 平板等宽屏：面板内容限宽居中，不做整屏拉伸（半模态容器本身全宽）
    .constraintSize({ maxWidth: 640 })
  }

  /** 面板分组标签 */
  @Builder
  panelLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.font_secondary'))
      .letterSpacing(1)
      .width('100%')
      .margin({ top: 12, left: 4, bottom: 6 })
  }

  /** 单实例内置项按钮文案：未添加=「添加」，已添加但停用=「启用」（对齐传统/AI 的状态按钮语义） */
  private singleAddLabel(p: ProviderDef): string {
    if (p.id === OFFLINE_PROVIDER.id) {
      return settingsStore.getOfflineAdded() ? '启用' : '添加';
    }
    return settingsStore.isBuiltinAdded(p.id) ? '启用' : '添加';
  }

  /** 免费服务商候选行（离线翻译复用同款行样式）：与其他服务商同款「添加」按钮，点击即加入引擎行 */
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

      Text(this.singleAddLabel(p))
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
      if (p.id === OFFLINE_PROVIDER.id) {
        this.addOffline();
      } else {
        this.addFree(p);
      }
    })
  }

  @Builder
  providerRow(p: ProviderDef) {
    Row({ space: 12 }) {
      // 服务商徽标：40×40 圆角方形，大字号更精神
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

      // 状态胶囊：已添加置灰弱化，待操作高亮（官方语义色）
      Text(this.statusLabel(this.providerStatus(p)))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.providerStatus(p) === 'added' ? $r('app.color.font_tertiary') : Color.White)
        .backgroundColor(this.providerStatus(p) === 'added'
          ? $r('app.color.bg_container') : $r('app.color.brand'))
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
      this.handleProviderTap(p);
    })
  }
}
