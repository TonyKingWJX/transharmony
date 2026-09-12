/**
 * 历史页：搜索 + 全部/收藏分段（SegmentButton）+ 语言对筛选（官方 ChipGroup）+ 记录列表。
 * 列表按官方长列表性能方案重构（harmonyos-guides「Repeat：可复用的循环渲染」）：
 * @ComponentV2 + Repeat.virtualScroll 懒加载（按需渲染可视区 + cachedCount 预加载区，
 * 离屏节点入缓存池复用），数据分页从 SQLite 按需加载，替代原 ForEach 全量渲染。
 * 懒加载模式不支持 V1 状态管理，故本页为 V2 组件；Index（V1）以基本类型 @Param 桥接
 * AppStorage（窗口宽度/历史版本号）。
 * 筛选条件（关键词/收藏/语言对）下推 SQLite（参数化 LIKE），变更后回卷首页重新分页。
 * 左滑删除单条（移入回收站）；多选模式可批量删除；点星标收藏；点击记录进详情页。
 * 进入多选：点头部「多选」或长按任意记录；多选时点击卡片切换勾选，
 * 底部浮出居中悬浮胶囊批量操作条（删除/取消，浮于列表上，列表底部留滚动余量）。
 * 回收站：卡片不放操作按钮（窄屏会溢出裁切），左滑露出「恢复 / 彻底删除」，顶栏一键清空。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ChipGroup,
  ChipGroupItemOptions,
  LengthMetrics,
  SegmentButton,
  SegmentButtonOptions,
  SegmentButtonItemTuple
} from '@kit.ArkUI';
import { historyStore, HistoryItem, HistoryQuery, HISTORY_VERSION_KEY } from '../services/HistoryStore';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { TransImageStore } from '../utils/TransImageStore';
import { LangCode } from '../models/TranslationTypes';

/** 每页加载条数：List.cachedCount 预渲染可视区外若干卡片，页大小对齐其量级 */
const PAGE_SIZE = 40;

interface LangFilter {
  key: string;
  label: string;
  from: LangCode;
  to: LangCode;
}

const LANG_FILTERS: LangFilter[] = [
  { key: 'all', label: '全部', from: '', to: '' },
  { key: 'zh-en', label: '中英', from: 'zh', to: 'en' },
  { key: 'zh-ja', label: '中日', from: 'zh', to: 'ja' },
  { key: 'zh-ko', label: '中韩', from: 'zh', to: 'ko' }
];

@ComponentV2
export struct HistoryPageContent {
  /** 当前页签序号（V1 父组件 Index 传入，简单类型可直接桥接，无需 UIUtils 兼容处理） */
  @Require @Param currentIndex: number;
  /** 沉浸式导航条避让高度（vp），由 Index 从 AppStorage 桥接 */
  @Param navBarH: number = 0;
  /** 窗口宽度（vp）：≥600 判定宽屏，内容限宽居中。由 Index 从 AppStorage 桥接 */
  @Param winW: number = 0;
  /** 历史数据版本号：任何写操作（翻译保存/收藏/删除/清空）后 bump，触发回卷重新查询 */
  @Param historyVersion: number = 0;
  /** 点击记录卡片：进入详情二级页（Index 注入回调，V2 组件不接 V1 @Consume 路由栈） */
  @Param onOpenDetail: (id: number) => void = (_id: number): void => {
  };
  /** 多选/回收站子模式变化上报（Index 用来隐藏底部胶囊页签、拦截返回键） */
  @Param onSubmodeChange: (active: boolean) => void = (_active: boolean): void => {
  };
  /** Index.onBackPress 拦截后递增的返回命令（多选态退出多选；回收站态回历史列表） */
  @Param backCmd: number = 0;
  /** 回收站模式：标题切「回收站」，列表显示已删记录（恢复/彻底删除/一键清空） */
  @Local recycleMode: boolean = false;
  @Local items: HistoryItem[] = [];
  @Local loading: boolean = true;
  @Local keyword: string = '';
  @Local favOnly: boolean = false;
  @Local langKey: string = 'all';
  /** 数据库符合当前筛选的总条数：分页追加的结束判据 */
  @Local totalCount: number = 0;
  /** 多选模式与已选记录 id 列表 */
  @Local selectMode: boolean = false;
  @Local selectedIds: number[] = [];
  /** 官方分段按钮：全部 / 收藏 */
  @Local segOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '全部' }, { text: '收藏' }] as SegmentButtonItemTuple,
    multiply: false
  });
  @Local segSelected: number[] = [0];
  /** 翻页占位：追加下一页时在列表顶部浮出，不整页闪烁 */
  @Local appending: boolean = false;
  /** 防重入：onReachEnd 触发频次可能高于查询完成速度 */
  private appendingLock: boolean = false;
  private searchTimer: number = -1;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  aboutToAppear(): void {
    this.reload();
  }

  aboutToDisappear(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  /** 历史任一写入后版本号 bump → V1 父组件传参变化 → 回卷首页重新查询 */
  @Monitor('historyVersion')
  onHistoryVersionChange(): void {
    this.reload();
  }

  /** 当前筛选条件（AppStorage/版本号驱动 reload；搜索框输入走防抖 reloadDebounced） */
  private query(): HistoryQuery {
    const f = LANG_FILTERS.find((it: LangFilter): boolean => it.key === this.langKey);
    const q: HistoryQuery = {
      keyword: this.keyword.trim(),
      favOnly: this.favOnly,
      fromLang: f !== undefined ? f.from : '',
      toLang: f !== undefined ? f.to : ''
    };
    return q;
  }

  /** 回卷首页重新查询（筛选条件变化 / 历史数据变化 / 模式切换）；回收站模式查已删记录 */
  private async reload(): Promise<void> {
    this.loading = true;
    try {
      const q = this.query();
      // ArkTS 不支持解构声明，分开 await
      const rows = this.recycleMode
        ? await historyStore.queryRecyclePage(q, PAGE_SIZE, 0)
        : await historyStore.queryPage(q, PAGE_SIZE, 0);
      const count = this.recycleMode
        ? await historyStore.countRecyclePage(q)
        : await historyStore.countPage(q);
      this.items = rows;
      this.totalCount = count;
    } catch (e) {
      this.items = [];
      this.totalCount = 0;
    } finally {
      this.loading = false;
    }
  }

  private reloadDebounced(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout((): void => {
      this.searchTimer = -1;
      this.reload();
    }, 300);
  }

  /** 懒加载翻页：向 SQLite 追加下一页，无更多数据或加载中则跳过 */
  private async appendNextPage(): Promise<void> {
    if (this.appendingLock || this.items.length >= this.totalCount) {
      return;
    }
    this.appendingLock = true;
    this.appending = true;
    try {
      const q = this.query();
      const rows = this.recycleMode
        ? await historyStore.queryRecyclePage(q, PAGE_SIZE, this.items.length)
        : await historyStore.queryPage(q, PAGE_SIZE, this.items.length);
      // 查询期间筛选/数据可能已变（reload 会整体替换数组），仅当仍是同一次会话时追加
      if (this.items.length > 0 || this.totalCount > 0) {
        this.items = this.items.concat(rows);
      }
    } finally {
      this.appendingLock = false;
      this.appending = false;
    }
  }

  // ---- 多选 / 回收站子模式 ----

  /** 子模式（多选或回收站）变化上报给 Index：隐藏底部胶囊页签、拦截返回键 */
  private notifySubmode(): void {
    this.onSubmodeChange(this.selectMode || this.recycleMode);
  }

  /** Index.onBackPress 拦截后广播：多选态退出多选；回收站态回历史列表 */
  @Monitor('backCmd')
  onBackCommand(): void {
    if (this.selectMode) {
      this.exitSelectMode();
    } else if (this.recycleMode) {
      this.exitRecycleMode();
    }
  }

  private toggleSelectMode(): void {
    if (this.selectMode) {
      this.exitSelectMode();
    } else {
      this.selectMode = true;
      this.notifySubmode();
    }
  }

  private exitSelectMode(): void {
    this.selectMode = false;
    this.selectedIds = [];
    this.notifySubmode();
  }

  private enterRecycleMode(): void {
    if (this.selectMode) {
      this.exitSelectMode();
    }
    this.recycleMode = true;
    this.notifySubmode();
    this.reload();
  }

  private exitRecycleMode(): void {
    this.recycleMode = false;
    this.notifySubmode();
    this.reload();
  }

  private isSelected(id: number): boolean {
    return this.selectedIds.includes(id);
  }

  /** 勾选/取消一条（重赋数组触发 V2 刷新） */
  private toggleItem(id: number): void {
    if (this.isSelected(id)) {
      this.selectedIds = this.selectedIds.filter((v: number): boolean => v !== id);
    } else {
      this.selectedIds = this.selectedIds.concat([id]);
    }
  }

  private allSelected(): boolean {
    return this.items.length > 0 && this.items.every((it: HistoryItem): boolean => this.isSelected(it.id));
  }

  private toggleSelectAll(): void {
    if (this.allSelected()) {
      this.selectedIds = [];
    } else {
      this.selectedIds = this.items.map((it: HistoryItem): number => it.id);
    }
  }

  /** 长按进入多选并选中该条 */
  private enterSelectWith(id: number): void {
    if (!this.selectMode) {
      this.selectMode = true;
      this.selectedIds = [id];
      this.notifySubmode();
    }
  }

  private confirmBatchDelete(): void {
    const n = this.selectedIds.length;
    hilog.info(0x0001, 'HistoryPage', '批量删除按钮点击 n=%{public}d', n);
    if (n === 0) {
      return;
    }
    this.getUIContext().showAlertDialog({
      message: '删除选中的 ' + n + ' 条记录吗？记录将移入回收站，30 天后自动清除。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Color.Red,
        action: (): void => {
          hilog.info(0x0001, 'HistoryPage', '确认弹窗点击删除');
          this.batchDelete();
        }
      }
    });
  }

  private async batchDelete(): Promise<void> {
    const n = this.selectedIds.length;
    if (n === 0) {
      return;
    }
    try {
      hilog.info(0x0001, 'HistoryPage', 'removeMany start n=%{public}d', n);
      await historyStore.removeMany(this.selectedIds);
      hilog.info(0x0001, 'HistoryPage', 'removeMany done');
      this.exitSelectMode();
      await this.reload();
      hilog.info(0x0001, 'HistoryPage', 'reload done items=%{public}d', this.items.length);
      this.toast('已删除 ' + n + ' 条，可在回收站恢复');
    } catch (e) {
      // 失败必须可见：此前无 catch，DB 异常静默失败在用户侧表现为「点了没反应」
      hilog.error(0x0001, 'HistoryPage', 'batchDelete failed: %{public}s', String(e));
      this.toast('删除失败，请重试');
    }
  }

  private async toggleFav(item: HistoryItem): Promise<void> {
    const next = item.favorite !== 1;
    await historyStore.setFavorite(item.id, next);
    // favorite 带 @Trace：直接改字段即精准刷新该卡片，无需重载数组
    item.favorite = next ? 1 : 0;
    this.toast(next ? '已收藏' : '已取消收藏');
  }

  /** 左滑：删除该条（移入回收站） */
  private async removeOne(id: number): Promise<void> {
    await historyStore.remove(id);
    await this.reload();
    this.toast('已删除，可在回收站恢复');
  }

  // ---- 回收站 ----

  /** 恢复单条回历史列表 */
  private async restoreOne(id: number): Promise<void> {
    try {
      await historyStore.restoreMany([id]);
      await this.reload();
      this.toast('已恢复');
    } catch (e) {
      hilog.error(0x0001, 'HistoryPage', 'restoreOne failed: %{public}s', String(e));
      this.toast('恢复失败，请重试');
    }
  }

  private confirmPurgeOne(item: HistoryItem): void {
    this.getUIContext().showAlertDialog({
      message: '彻底删除这条记录吗？该操作不可恢复。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '彻底删除',
        fontColor: Color.White,
        backgroundColor: $r('app.color.warning'),
        action: (): void => {
          this.purgeOne(item.id);
        }
      }
    });
  }

  private async purgeOne(id: number): Promise<void> {
    try {
      await historyStore.purgeMany([id]);
      await TransImageStore.cleanOrphans(getContext(this) as common.Context);
      await this.reload();
      this.toast('已彻底删除');
    } catch (e) {
      hilog.error(0x0001, 'HistoryPage', 'purgeOne failed: %{public}s', String(e));
      this.toast('删除失败，请重试');
    }
  }

  private confirmClearRecycle(): void {
    if (this.items.length === 0) {
      this.toast('回收站为空');
      return;
    }
    this.getUIContext().showAlertDialog({
      message: '清空回收站吗？' + this.items.length + ' 条记录将被彻底删除，该操作不可恢复。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {}
      },
      secondaryButton: {
        value: '清空',
        fontColor: Color.White,
        backgroundColor: $r('app.color.warning'),
        action: (): void => {
          this.clearRecycle();
        }
      }
    });
  }

  private async clearRecycle(): Promise<void> {
    try {
      await historyStore.purgeRecycleAll();
      await TransImageStore.cleanOrphans(getContext(this) as common.Context);
      await this.reload();
      this.toast('已清空回收站');
    } catch (e) {
      hilog.error(0x0001, 'HistoryPage', 'clearRecycle failed: %{public}s', String(e));
      this.toast('清空失败，请重试');
    }
  }

  private async copyResult(item: HistoryItem): Promise<void> {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.result);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('译文已复制');
  }

  /** 列表项左滑配置：普通态=删除（移入回收站）；回收站态=恢复 + 彻底删除 */
  private swipeOpts(item: HistoryItem): SwipeActionOptions {
    const end: SwipeActionItem = {
      builder: (): void => {
        if (this.recycleMode) {
          this.recycleSwipeArea(item);
        } else {
          this.deleteArea(item);
        }
      }
    };
    const opts: SwipeActionOptions = {
      end: end,
      edgeEffect: SwipeEdgeEffect.None
    };
    return opts;
  }

  private enginePill(item: HistoryItem): string {
    if (item.engineId.startsWith('ai-')) {
      return 'AI';
    }
    if (item.engineId === 'edge') {
      return '微软翻译';
    }
    if (item.engineId === 'aliyun') {
      return '阿里云';
    }
    if (item.engineId === 'alibaba') {
      return '阿里翻译';
    }
    if (item.engineId === 'youdao') {
      return '有道翻译';
    }
    if (item.engineId === 'tencent') {
      return '腾讯云';
    }
    if (item.engineId === 'azure') {
      return 'Azure';
    }
    if (item.engineId === 'baidu') {
      return '百度';
    }
    return item.engineId;
  }

  private fmtTime(ts: number): string {
    const d = new Date(ts);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return (d.getMonth() + 1).toString() + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  /** 语言对筛选 chips（官方 ChipGroup 数据源） */
  private langChipItems(): ChipGroupItemOptions[] {
    const items: ChipGroupItemOptions[] = [];
    for (const f of LANG_FILTERS) {
      items.push({ label: { text: f.label } });
    }
    return items;
  }

  private langChipIndex(): number {
    const idx = LANG_FILTERS.findIndex((f: LangFilter): boolean => f.key === this.langKey);
    return idx >= 0 ? idx : 0;
  }

  /** 宽屏内容最大宽度（vp）：md（双折叠展开）720；lg 及以上（平板）880；窄屏不限 */
  private contentMaxW(): number {
    if (this.winW >= 840) {
      return 880;
    }
    return this.winW >= 600 ? 720 : 100000;
  }

  build() {
    Column() {
      // 居中限宽容器：平板等宽屏下列表/表单最大 720vp 居中，不做整屏拉伸
      Column() {
      // 主页大标题栏：普通列表 = 回收站 + 多选；回收站态 = 返回 + 一键清空；
      // 多选中标题显示已选数量，操作收敛到底部批量条
      Row() {
        if (this.recycleMode) {
          this.circleBtn($r('sys.symbol.chevron_left'), $r('app.color.font_secondary'), (): void => {
            this.exitRecycleMode();
          })
        }
        Text(this.selectMode ? '已选 ' + this.selectedIds.length + ' 项'
          : (this.recycleMode ? '回收站' : '历史'))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.recycleMode) {
          Text('一键清空')
            .fontSize(13)
            .fontColor($r('app.color.warning'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor($r('app.color.bg_container'))
            .onClick(() => {
              this.confirmClearRecycle();
            })
        } else if (!this.selectMode) {
          // 一键清空入口改为回收站（改成文字）：清空动作挪进回收站页
          Text('回收站')
            .fontSize(13)
            .fontColor($r('app.color.font_secondary'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor($r('app.color.bg_container'))
            .margin({ right: 8 })
            .onClick(() => {
              this.enterRecycleMode();
            })
          // 多选入口/退出按钮拆成两个分支各传常量：@Builder 按值传参不会随
          // 状态变化刷新（首帧后图标/颜色定格），用三元表达式在同一调用点
          // 切换参数时，进入多选后按钮会停留在旧的蓝色对勾上
          this.circleBtn($r('sys.symbol.checkmark_circle'), $r('app.color.brand'), (): void => {
            this.toggleSelectMode();
          })
        } else {
          this.circleBtn($r('sys.symbol.xmark'), $r('app.color.font_secondary'), (): void => {
            this.toggleSelectMode();
          })
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Column({ space: 10 }) {
        // 官方 Search 组件（自带放大镜与清除按钮）；回收站模式隐藏筛选区
        if (!this.recycleMode) {
          Search({ value: this.keyword, placeholder: '搜索原文或译文…' })
          .height(40)
          .width('100%')
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(999)
          .border({ width: 0.8, color: $r('app.color.divider') })
          .placeholderFont({ size: 14 })
          .placeholderColor($r('app.color.font_tertiary'))
          .textFont({ size: 14 })
          .fontColor($r('app.color.font_primary'))
          .searchIcon({ color: $r('app.color.font_tertiary') })
          .cancelButton({ style: CancelButtonStyle.INPUT })
          .onChange((value: string): void => {
            this.keyword = value;
            this.reloadDebounced();
          })

        // 官方分段按钮 + 语言对筛选
        // SegmentButton/ChipGroup 内部是 V1 组件（@Link），V2 组件不能直接向其
        // @Link 传参，包一层 V1 壳组件隔离（壳内持有 @State，回调上抛）
        HistorySegButton({
          options: this.segOptions,
          selected: this.segSelected[0],
          onPick: (index: number): void => {
            this.favOnly = index === 1;
            this.segSelected = [index];
            this.reload();
          }
        })
          .width('100%')

        HistoryChipGroup({
          items: this.langChipItems(),
          selected: this.langChipIndex(),
          onPick: (index: number): void => {
            if (index >= 0 && index < LANG_FILTERS.length) {
              this.langKey = LANG_FILTERS[index].key;
              this.reload();
            }
          }
        })
        }

        // 多选态：全选行（已加载数据内全选；批量删除等同清空）
        if (this.selectMode) {          Row({ space: 8 }) {
            SymbolGlyph(this.allSelected()
              ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
              .fontSize(18)
              .fontColor([this.allSelected() ? $r('app.color.brand') : $r('app.color.font_fourth')])
            Text(this.allSelected() ? '取消全选' : '全选')
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
          }
          .width('100%')
          .padding({ left: 4, top: 2, bottom: 2 })
          .onClick(() => {
            this.toggleSelectAll();
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      if (this.loading) {
        // 容器撑满中部：否则多选态下批量操作条会紧跟内容浮在屏幕中间
        Column() {
          LoadingProgress().width(32).height(32).margin({ top: 80 }).color($r('app.color.brand'))
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.items.length === 0) {
        Column() {
          Column({ space: 8 }) {
            SymbolGlyph(this.recycleMode ? $r('sys.symbol.ohos_trash') : $r('sys.symbol.clock'))
              .fontSize(40)
              .fontColor([$r('app.color.font_fourth')])
            Text(this.recycleMode ? '回收站为空' : '暂无翻译记录')
              .fontSize(14)
              .fontColor($r('app.color.font_tertiary'))
            if (this.recycleMode) {
              Text('删除的历史记录会在这里保留 30 天')
                .fontSize(11)
                .fontColor($r('app.color.font_fourth'))
            }
          }
          .margin({ top: 90 })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // Repeat 懒加载长列表（官方推荐替代 ForEach/LazyForEach）：
        // virtualScroll 只渲染可视区 + cachedCount 预加载区，离屏节点复用。
        // alignContent Bottom：多选态悬浮小框贴底；List/渐隐层自身 height('100%') 填满，不受对齐影响
        Stack({ alignContent: Alignment.Bottom }) {
          List({ space: 0 }) {
            Repeat<HistoryItem>(this.items)
              .each((ri: RepeatItem<HistoryItem>) => {
                ListItem() {
                  this.historyCard(ri)
                }
                .margin({ bottom: 8 })
                // 仅多选态收起滑动操作（避免与点击勾选冲突）；
                // 普通态左滑删除，回收站态左滑恢复/彻底删除
                .swipeAction(this.selectMode ? {} : this.swipeOpts(ri.item))
              })
              .key((item: HistoryItem): string => item.id.toString() + '_' + item.favorite.toString())
              .virtualScroll({ totalCount: this.totalCount })
          }
          .width('100%')
          .height('100%')
          .cachedCount(8)
          .onReachEnd(() => {
            this.appendNextPage();
          })
          // 底部 padding：多选态为悬浮小框留出滚动余量（框高 60 + 上下间隙 24），
          // 滚到底时最后一张卡完整显示在小框上方；普通/回收站态维持 12
          .padding({ left: 16, right: 16, top: 12,
            bottom: (this.selectMode ? 84 : 12) + this.navBarH })
          .scrollBar(BarState.Off)
          // alwaysEnabled：内容不满一屏时也响应拖拽回弹（默认内容小于容器不响应手势）
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 官方边缘渐隐（API 14+）：内容接近组件边缘时 alpha 渐隐，无布局占用。
          // 三态恒开：多选/回收站态列表底部空隙 84+navBarH（>40vp 渐隐带），
          // 静止时最后一张卡完整不洗白；禁用会让卡片滚出边缘时生硬裁切，
          // 看起来像被一层背景色「蒙版」盖住
          .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(40) })

          // 页内底部渐隐层：盖在列表上方且不拦截点击，滚动内容经过时淡出，
          // 视觉与 Index 公共渐隐层一致（不依赖其 z 序是否覆盖本页）；
          // 多选/回收站态隐藏，避免盖住最后一张卡
          Column() {
            Column()
              .width('100%')
              .height(112)
              .linearGradient({
                angle: 180,
                colors: [[$r('app.color.fade_from'), 0.0], [$r('app.color.bg_page'), 1.0]]
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .hitTestBehavior(HitTestMode.None)
          .visibility(this.selectMode || this.recycleMode ? Visibility.None : Visibility.Visible)

          // 多选态悬浮小框：浮在列表底部之上（官方 FAB 模式），列表底部
          // padding 已为它留出滚动余量；居中由 Stack 对齐 + 自身 margin 承载
          if (this.selectMode) {
            Row({ space: 10 }) {
              Button('删除')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .height(40)
                .borderRadius(20)
                .backgroundColor(this.selectedIds.length > 0 ? $r('app.color.warning') : $r('app.color.bg_container'))
                .fontColor(this.selectedIds.length > 0 ? Color.White : $r('app.color.font_fourth'))
                .enabled(this.selectedIds.length > 0)
                .onClick(() => {
                  this.confirmBatchDelete();
                })
              Button('取消')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.bg_container'))
                .fontColor($r('app.color.font_secondary'))
                .onClick(() => {
                  this.exitSelectMode();
                })
            }
            .width(300)
            .padding(10)
            .borderRadius(30)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .shadow({ radius: 24, color: 'rgba(0,0,0,0.14)', offsetY: 6 })
            .margin({ bottom: this.navBarH + 12 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
          }
        }
        .width('100%')
        .layoutWeight(1)

        // 翻页占位：仅追加下一页时显示，不整页闪烁
        if (this.appending) {
          Row() {
            LoadingProgress().width(22).height(22).color($r('app.color.brand'))
            Text('加载中')
              .fontSize(12)
              .fontColor($r('app.color.font_tertiary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 8, bottom: 68 + this.navBarH + 8 })
        }
      }
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: this.contentMaxW() })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .alignItems(HorizontalAlign.Center)
  }

  /** 单条历史卡片（Repeat 子组件须有且仅有一个根节点） */
  @Builder
  historyCard(ri: RepeatItem<HistoryItem>) {
    Row() {
      // 多选勾选圈：选中实心对勾，未选空心圆
      if (this.selectMode) {
        SymbolGlyph(this.isSelected(ri.item.id)
          ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(20)
          .fontColor([this.isSelected(ri.item.id)
            ? $r('app.color.brand') : $r('app.color.font_fourth')])
          .margin({ right: 10 })
      }

      Column() {
        Text(ri.item.source)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .lineHeight(19)
          .fontColor($r('app.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(ri.item.result)
          .fontSize(14)
          .lineHeight(18)
          .fontColor($r('app.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 })

        Row({ space: 8 }) {
          Text(this.enginePill(ri.item))
            .fontSize(11)
            .fontColor(ri.item.engineId.startsWith('ai-') ? $r('app.color.brand') : $r('app.color.font_tertiary'))
            .border({ width: 0.8, color: ri.item.engineId.startsWith('ai-')
              ? $r('app.color.brand') : $r('app.color.divider') })
            .borderRadius(999)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          Text(TranslateUseCase.describePair(ri.item.fromLang, ri.item.toLang))
            .fontSize(11)
            .fontColor($r('app.color.font_tertiary'))
          Text(this.fmtTime(ri.item.createdAt))
            .fontSize(11)
            .fontColor($r('app.color.font_tertiary'))
          Blank()
          // 回收站操作改为左滑（recycleSwipeArea），卡内不放按钮：
          // 引擎/语言对/时间 + 两个按钮会超出窄屏宽度，右侧被裁切
          if (!this.recycleMode && !this.selectMode) {
            SymbolGlyph(ri.item.favorite === 1 ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
              .fontSize(16)
              .fontColor([ri.item.favorite === 1 ? '#E8A123' : $r('app.color.font_fourth')])
              .onClick(() => {
                this.toggleFav(ri.item);
              })
          }
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 15, right: 15, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: this.isSelected(ri.item.id) ? 1.2 : 0.8,
      color: this.isSelected(ri.item.id) ? $r('app.color.brand') : $r('app.color.divider') })
    .gesture(LongPressGesture()
      .onAction(() => {
        // 多选态长按无附加动作；普通态长按进入多选并选中该条
        this.enterSelectWith(ri.item.id);
      }))
    .onClick(() => {
      if (this.selectMode) {
        this.toggleItem(ri.item.id);
      } else if (this.recycleMode) {
        // 回收站：点击无动作（操作在卡片右侧按钮）
      } else {
        // 进入详情二级页（编辑重译/朗读/收藏）；复制等操作在详情页内完成
        this.onOpenDetail(ri.item.id);
      }
    })
  }

  /** 头部圆形图标按钮 */
  @Builder
  circleBtn(icon: Resource, iconColor: ResourceColor, onTap: () => void) {
    Stack() {
      Circle()
        .width(36)
        .height(36)
        .fill($r('app.color.card_bg'))
        .stroke($r('app.color.divider'))
        .strokeWidth(0.8)
      SymbolGlyph(icon)
        .fontSize(16)
        .fontColor([iconColor])
    }
    .width(36)
    .height(36)
    .margin({ left: 10 })
    .onClick(() => {
      onTap();
    })
  }

  /** 列表左滑：删除 */
  @Builder
  deleteArea(item: HistoryItem) {
    Row() {
      Column({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.ohos_trash'))
          .fontSize(17)
          .fontColor([Color.White])
        Text('删除')
          .fontSize(11)
          .fontColor(Color.White)
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .backgroundColor($r('app.color.warning'))
    .margin({ left: 8 })
    .onClick(() => {
      this.removeOne(item.id);
    })
  }

  /** 回收站左滑操作区：恢复（品牌色）+ 彻底删除（警示色，二次确认） */
  @Builder
  recycleSwipeArea(item: HistoryItem) {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
          .fontSize(17)
          .fontColor([Color.White])
        Text('恢复')
          .fontSize(11)
          .fontColor(Color.White)
      }
      .width(64)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .backgroundColor($r('app.color.brand'))
      .onClick(() => {
        this.restoreOne(item.id);
      })

      Column({ space: 3 }) {
        SymbolGlyph($r('sys.symbol.ohos_trash'))
          .fontSize(17)
          .fontColor([Color.White])
        Text('彻底删除')
          .fontSize(11)
          .fontColor(Color.White)
          .maxLines(1)
      }
      .width(72)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .backgroundColor($r('app.color.warning'))
      .onClick(() => {
        this.confirmPurgeOne(item);
      })
    }
    .height('100%')
    .margin({ left: 8 })
  }
}

/**
 * SegmentButton 的 V1 壳：官方组件内部用 @Link 持有选中项，V2 组件不能直接向
 * V1 @Link 传参（arkts 编译限制）。壳内以 @State 中转：外部单值 selected 变化时
 * 同步给 @State selectedIndexes；点击后回传 onPick，由父组件收敛状态。
 */
@Component
struct HistorySegButton {
  @Prop options: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: ' ' }, { text: ' ' }] as SegmentButtonItemTuple
  });
  @Prop selected: number = 0;
  onPick: (index: number) => void = (): void => {};
  @State selectedIndexes: number[] = [0];

  aboutToAppear(): void {
    this.selectedIndexes = [this.selected];
  }

  build() {
    SegmentButton({
      options: this.options,
      selectedIndexes: this.selectedIndexes,
      onItemClicked: (index: number): void => {
        this.selectedIndexes = [index];
        this.onPick(index);
      }
    })
  }
}

/** ChipGroup 的 V1 壳，作用同 HistorySegButton */
@Component
struct HistoryChipGroup {
  @Prop items: ChipGroupItemOptions[] = [];
  @Prop selected: number = 0;
  onPick: (index: number) => void = (): void => {};
  @State selectedIndexes: number[] = [0];

  aboutToAppear(): void {
    this.selectedIndexes = [this.selected];
  }

  build() {
    ChipGroup({
      items: this.items,
      selectedIndexes: this.selectedIndexes,
      onChange: (sel: Array<number>): void => {
        if (sel.length > 0) {
          this.onPick(sel[0]);
        }
      }
    })
  }
}
