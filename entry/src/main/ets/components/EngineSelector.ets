/**
 * 引擎选择行：状态按钮（chip）横滑行，样式对齐官方 Chip 组件规格
 * （sys.float.chip_small_* 系统参数：高度/圆角/字号/图标/内边距）。
 * - 免费通道（微软/有道）与用户服务 chip 放在横向 List 中，通过官方拖拽排序
 *   （List + ForEach.onMove）长按浮起即可拖动调整顺序，无需切换模式；
 *   「聚合翻译」固定在用户 chip 之后，不参与排序；
 * - 点击 chip 切换引擎（弹跳动画）；行尾「管理」chip 进入管理态——
 *   用户服务 chip 出现关闭按钮（×）并高亮，chip 变为「完成」，点击退出；
 * - 排序落位后整行顺序写入 settingsStore 引擎行顺序；
 *   两个用户服务之间排序时由宿主同步服务列表（聚合返回）顺序；
 * - 服务列表变化（启用/停用/排序/新增）由 AppStorage「ux_pill_version」触发整行重算（跨页同步）。
 * 注意：chip 上不得绑定自定义长按手势——系统拖拽同为「长按500ms+移动」触发，
 * 同节点二者按阈值二选一竞争，会导致要么拖不动、要么长按失效（官方手势冲突文档）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { EngineRegistry } from '../services/EngineRegistry';
import { settingsStore } from '../services/SettingsStore';
import { findDef } from '../services/ProviderCatalog';
import { OFFLINE_ENGINE_ID, OFFLINE_FEATURE_ENABLED } from '../services/OfflineTranslator';

export const AGGREGATE_ID = 'aggregate';

export const PILL_VERSION_KEY = 'ux_pill_version';

/** 引擎 chip 展示信息 */
export interface EngineChipInfo {
  id: string;
  label: string;
  isAI: boolean;
  /** 用户服务实例：管理态下出现关闭按钮（×，停用） */
  closable: boolean;
  /** 是否参与拖拽排序（横向 List 内的 chip；聚合翻译固定行尾不参与） */
  sortable: boolean;
}

@Component
export struct EngineSelector {
  @Link engineId: string;
  /** 服务列表变更版本号：任意页 bump 后重算 chip 清单 */
  @StorageProp('ux_pill_version') @Watch('rebuildChips') pillVersion: number = 0;
  onPick: (id: string) => void = (id: string): void => {};
  /** 排序落位后通知宿主（fromId/toId 为参与排序的两个 chip id），用于同步用户服务列表顺序 */
  onReorder: (fromId: string, toId: string) => void = (fromId: string, toId: string): void => {};
  /** 关闭（停用）用户服务（仅管理态） */
  onDisable: (id: string) => void = (id: string): void => {};
  /** 打开添加服务商面板 */
  onAdd: () => void = (): void => {};
  /** 是否显示「聚合翻译」chip（图片翻译面板等单引擎场景可关闭） */
  showAggregate: boolean = true;

  /** 管理态：「管理」chip 进入（× 显示、chip 高亮），点「完成」退出 */
  @State editMode: boolean = false;
  /** 排序数据源：List onMove 要求在回调中 splice 本数组，才能驱动落位动画 */
  @State chipList: EngineChipInfo[] = [];
  /** 点击弹跳动画中的 chip id */
  @State popId: string = '';

  aboutToAppear(): void {
    this.rebuildChips();
  }

  private isConfiguredSvc(serviceId: string): boolean {
    const svc = settingsStore.getService(serviceId);
    if (svc === undefined) {
      return false;
    }
    // Bob 插件实例：装好即已配置（选项值在加载时注入，缺省走 defaultValue）
    if (svc.defId.startsWith('plugin:')) {
      return true;
    }
    const def = findDef(svc.defId);
    if (def === undefined) {
      return false;
    }
    for (const f of def.fields) {
      if (!f.optional && (svc.config[f.key] ?? '').length === 0) {
        return false;
      }
    }
    return true;
  }

  /** chip 清单：免费通道（默认关闭，面板/管理页开启后出现，管理态可删）
   *  + 用户服务（已启用且已配置），按存储的引擎行顺序排列。
   *  引擎表未就绪（bootstrap 未完成）时返回空行：留白优于显示原始 id 等错误状态。 */
  private computeChips(): EngineChipInfo[] {
    if (!EngineRegistry.isReady()) {
      return [];
    }
    const services = settingsStore.getServices();
    hilog.info(0x0001, 'EngineSel', 'chips: v=%{public}d services=%{public}d engineId=%{public}s',
      this.pillVersion, services.length, this.engineId);
    const infos: EngineChipInfo[] = [];
    for (const id of settingsStore.getBuiltinOrder()) {
      if (!settingsStore.isBuiltinActive(id)) {
        continue;
      }
      const adapter = EngineRegistry.byId(id);
      infos.push({
        id: id,
        label: adapter !== undefined ? adapter.label : id,
        isAI: false,
        closable: true,
        sortable: true
      });
    }
    // 离线翻译（端侧内置模型）：生效中即出现在免费通道之后，排序经引擎行顺序键自由调整
    if (OFFLINE_FEATURE_ENABLED && settingsStore.isOfflineActive()) {
      const offline = EngineRegistry.byId(OFFLINE_ENGINE_ID);
      infos.push({
        id: OFFLINE_ENGINE_ID,
        label: offline !== undefined ? offline.label : '离线翻译',
        isAI: false,
        closable: true,
        sortable: true
      });
    }
    for (const s of services) {
      const adapter = EngineRegistry.byId(s.id);
      if (adapter === undefined || !s.enabled) {
        continue;
      }
      if (adapter.needsConfig && !this.isConfiguredSvc(s.id)) {
        continue;
      }
      infos.push({ id: s.id, label: adapter.label, isAI: adapter.isAI, closable: true, sortable: true });
    }
    // 按存储顺序重排：已失效的 id 忽略，未记录的新 chip 保持默认相对顺序追加在尾部
    const order = settingsStore.getEngineChipOrder();
    if (order.length === 0) {
      return infos;
    }
    const ordered: EngineChipInfo[] = [];
    for (const id of order) {
      for (const info of infos) {
        if (info.id === id) {
          ordered.push(info);
          break;
        }
      }
    }
    for (const info of infos) {
      if (!order.includes(info.id)) {
        ordered.push(info);
      }
    }
    return ordered;
  }

  /** 版本号变化（服务增删/开关/顺序落盘等）时重算排序数据源 */
  private rebuildChips(): void {
    this.chipList = this.computeChips();
  }

  /** 点击弹跳动效：短暂放大后回落 */
  private pop(id: string): void {
    this.popId = id;
    setTimeout(() => {
      this.popId = '';
    }, 200);
  }

  /** 拖拽落位（List onMove）：splice 数据源驱动落位动画，随后持久化整行顺序 */
  private handleMove(from: number, to: number): void {
    if (from < 0 || to < 0 || from === to || from >= this.chipList.length || to >= this.chipList.length) {
      return;
    }
    const fromId = this.chipList[from].id;
    const toId = this.chipList[to].id;
    const moved = this.chipList.splice(from, 1);
    this.chipList.splice(to, 0, moved[0]);
    const ids: string[] = [];
    for (const info of this.chipList) {
      ids.push(info.id);
    }
    settingsStore.setEngineChipOrder(ids);
    // 两个用户服务之间排序时，宿主同步服务列表顺序（免费通道不在服务列表，宿主侧自动忽略）
    this.onReorder(fromId, toId);
  }

  build() {
    Scroll() {
      Row({ space: 8 }) {
        // 横向 List 承载全部可排序 chip（内容自适应宽度，整行滚动由外层 Scroll 负责）
        List({ space: 8 }) {
          ForEach(this.chipList, (info: EngineChipInfo) => {
            ListItem() {
              this.chip(info)
            }
          }, (info: EngineChipInfo) => info.id + '_' + info.label)
            // 官方拖拽排序：长按 chip 浮起拖动，离手触发 onMove（无条件挂载，
            // 不能按状态传 undefined——拖拽能力在节点创建时注册，事后补挂不生效）
            .onMove((from: number, to: number): void => {
              this.handleMove(from, to);
            })
        }
        .listDirection(Axis.Horizontal)
        .alignListItem(ListItemAlign.Center)
        .scrollBar(BarState.Off)
        .enableScrollInteraction(false)

        if (this.showAggregate) {
          this.aggregateChip()
        }
        this.addChip()
        if (this.editMode) {
          this.doneChip()
        } else {
          this.manageChip()
        }
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 2, right: 2 })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    // chips 总宽不足时靠左排列（Scroll 默认居中会在宽屏下飘到中间）
    .align(Alignment.Start)
    .scrollBar(BarState.Off)
  }

  @Builder
  chip(info: EngineChipInfo) {
    Row({ space: 4 }) {
      // 标签区：点击切换引擎（管理态下不响应，避免整理时误切）
      Row({ space: 5 }) {
        if (info.isAI) {
          SymbolGlyph($r('sys.symbol.AI'))
            .fontSize($r('sys.float.chip_small_icon_size'))
            .fontColor([this.engineId === info.id ? Color.White : $r('app.color.brand')])
        }
        Text(info.label)
          .fontSize($r('sys.float.chip_small_font_size'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.engineId === info.id ? $r('sys.color.ohos_id_color_text_primary_contrary')
            : $r('app.color.font_secondary'))
      }
      .onClick(() => {
        if (this.editMode) {
          return;
        }
        this.pop(info.id);
        this.onPick(info.id);
      })

      // 关闭按钮：仅管理态 + 用户服务实例（停用后从行中消失，可在添加面板重新启用）
      if (info.closable && this.editMode) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('sys.float.chip_small_icon_size'))
          .fontColor([this.engineId === info.id ? $r('sys.color.ohos_id_color_text_primary_contrary')
            : $r('app.color.font_secondary')])
          .padding(2)
          .transition(TransitionEffect.OPACITY.animation({ duration: 150 })
            .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 })))
          .onClick(() => {
            this.onDisable(info.id);
          })
      }
    }
    .alignItems(VerticalAlign.Center)
    .height($r('sys.float.chip_small_height'))
    .padding({
      left: $r('sys.float.chip_small_text_padding'),
      right: $r('sys.float.chip_small_text_padding'),
      top: 4,
      bottom: 4
    })
    .borderRadius($r('sys.float.chip_small_radius'))
    .backgroundColor(this.engineId === info.id && !info.isAI ? $r('app.color.brand') : $r('app.color.bg_container'))
    .linearGradient(this.engineId === info.id && info.isAI
      ? { angle: 135, colors: [['#7B5CFF', 0.0], ['#0A59F7', 1.0]] }
      : { angle: 135, colors: [['#00000000', 0.0], ['#00000000', 1.0]] })
    .border({
      width: this.editMode && info.sortable ? 1 : 0.5,
      color: this.editMode && info.sortable ? $r('app.color.brand') : $r('app.color.mat_line')
    })
    .scale({ x: this.popId === info.id ? 1.06 : 1, y: this.popId === info.id ? 1.06 : 1 })
    .animation({ duration: 200, curve: Curve.EaseOut })
  }

  /** 聚合翻译 chip：固定在用户 chip 之后，不参与排序/关闭 */
  @Builder
  aggregateChip() {
    this.chip({ id: AGGREGATE_ID, label: '聚合翻译', isAI: false, closable: false, sortable: false })
  }

  @Builder
  addChip() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize($r('sys.float.chip_small_icon_size'))
        .fontColor([$r('app.color.brand')])
      Text('添加')
        .fontSize($r('sys.float.chip_small_font_size'))
        .fontColor($r('app.color.brand'))
    }
    .alignItems(VerticalAlign.Center)
    .height($r('sys.float.chip_small_height'))
    .padding({
      left: $r('sys.float.chip_small_text_padding'),
      right: $r('sys.float.chip_small_text_padding'),
      top: 4,
      bottom: 4
    })
    .borderRadius($r('sys.float.chip_small_radius'))
    .border({ width: 1, color: $r('app.color.brand') })
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.onAdd();
    })
  }

  /** 行尾「管理」chip：进入管理态（用户服务 chip 出现 ×、可停用） */
  @Builder
  manageChip() {
    Text('管理')
      .fontSize($r('sys.float.chip_small_font_size'))
      .fontColor($r('app.color.font_secondary'))
      .padding({
        left: $r('sys.float.chip_small_text_padding'),
        right: $r('sys.float.chip_small_text_padding'),
        top: 4,
        bottom: 4
      })
      .borderRadius($r('sys.float.chip_small_radius'))
      .border({ width: 1, color: $r('app.color.mat_line') })
      .backgroundColor($r('app.color.bg_container'))
      .onClick(() => {
        this.editMode = true;
      })
  }

  /** 管理态行尾「完成」chip：点击退出管理态 */
  @Builder
  doneChip() {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize($r('sys.float.chip_small_icon_size'))
        .fontColor([Color.White])
      Text('完成')
        .fontSize($r('sys.float.chip_small_font_size'))
        .fontColor(Color.White)
    }
    .alignItems(VerticalAlign.Center)
    .height($r('sys.float.chip_small_height'))
    .padding({
      left: $r('sys.float.chip_activated_small_text_padding'),
      right: $r('sys.float.chip_activated_small_text_padding'),
      top: 4,
      bottom: 4
    })
    .borderRadius($r('sys.float.chip_small_radius'))
    .backgroundColor($r('app.color.brand'))
    .onClick(() => {
      this.editMode = false;
    })
  }
}

/** 供面板/设置使用的引擎显示名（含 AI 预置） */
export function engineLabel(id: string): string {
  const hit = EngineRegistry.byId(id);
  return hit !== undefined ? hit.label : id;
}
