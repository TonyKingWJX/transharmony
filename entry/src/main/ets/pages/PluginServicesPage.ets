import { common } from '@kit.AbilityKit';
import { fileIo, picker, fileUri } from '@kit.CoreFileKit';
import { PluginInstaller, InstalledPlugin } from '../services/plugin/PluginInstaller';
import { PLUGIN_DEF_PREFIX, pluginServiceId, bobPluginEngine } from '../services/plugin/BobPluginEngine';
import {
  manggoServiceId,
  manggoDefId,
  parseManggoServices,
  isSupportedManggoService
} from '../services/plugin/ManggoTypes';
import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

/**
 * 插件服务管理页（NavDestination 二级页，从「翻译服务」进入）：
 *  - 导入 .bobplugin（系统文件管理器选择，翻译 / 语音 TTS / 文字识别 OCR 三类，按 category 自动归入板块）；
 *  - 三个板块：翻译服务 / 语音服务TTS / 文字识别服务OCR，无相应插件时板块整体隐藏；
 *  - 行内：点击进插件配置页、开关（启用状态）、删除（二次确认）；
 *  - 翻译插件启用后进引擎行/聚合；TTS/OCR 插件的执行接入在后续版本（先管理）。
 */

/** 板块定义：标题 + 对应类别 */
interface PluginSection {
  title: string;
  category: string; // translate | tts | ocr
}

const SECTIONS: PluginSection[] = [
  { title: '翻译服务', category: 'translate' },
  { title: '语音服务TTS', category: 'tts' },
  { title: '文字识别服务OCR', category: 'ocr' }
];

function categoryLabel(category: string): string {
  if (category === 'tts') {
    return '语音';
  }
  if (category === 'ocr') {
    return '识别';
  }
  return '翻译';
}

/** 来源徽标文案：'bob' → Bob（蓝）；'manggo' → Manggo（橘）。旧记录缺省按 bob */
function sourceLabel(rec: InstalledPlugin): string {
  return rec.source === 'manggo' ? 'Manggo' : 'Bob';
}

@Component
export struct PluginServicesPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 已安装插件清单（按类别分组展示） */
  @State plugins: InstalledPlugin[] = [];
  @State importing: boolean = false;
  /** 加载失败/无图标的插件：回退首字头像 */
  private brokenIcons: Set<string> = new Set();
  @State iconTick: number = 0;

  /** 插件图标（Bob info.json icon / manggo 清单 icon），无或已失败返回空串 */
  private pluginIconUrl(rec: InstalledPlugin): string {
    if (this.brokenIcons.has(rec.pluginId)) {
      return '';
    }
    return PluginInstaller.pluginIconPath(rec);
  }

  private markIconBroken(key: string): void {
    if (!this.brokenIcons.has(key)) {
      this.brokenIcons.add(key);
      this.iconTick++;
    }
  }

  aboutToAppear(): void {
    this.refresh();
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private bumpPill(): void {
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  private async refresh(): Promise<void> {
    this.plugins = await PluginInstaller.list(this.ctx());
  }

  private byCategory(category: string): InstalledPlugin[] {
    return this.plugins.filter((p: InstalledPlugin): boolean => p.category === category);
  }

  private isEnabled(rec: InstalledPlugin): boolean {
    // Manggo 多服务插件：任一服务启用即视为启用；Bob：单服务实例
    if (rec.source === 'manggo') {
      const prefix = `plugin-${rec.pluginId}#`;
      const services = settingsStore.getServices();
      for (const s of services) {
        if ((s.id.startsWith(prefix) || s.id === pluginServiceId(rec.pluginId)) && s.enabled) {
          return true;
        }
      }
      return false;
    }
    const svc = settingsStore.getService(pluginServiceId(rec.pluginId));
    return svc !== undefined && svc.enabled;
  }

  /** 显示名：用户在配置页改过名则优先（ServiceItem.name），否则用清单的 name */
  private displayName(rec: InstalledPlugin): string {
    if (rec.source === 'manggo') {
      const prefix = `plugin-${rec.pluginId}#`;
      const services = settingsStore.getServices();
      for (const s of services) {
        if (s.id.startsWith(prefix) && s.name.length > 0) {
          return s.name;
        }
      }
      return rec.name;
    }
    const svc = settingsStore.getService(pluginServiceId(rec.pluginId));
    if (svc !== undefined && svc.name.length > 0) {
      return svc.name;
    }
    return rec.name;
  }

  /** 开关：整体启停（Manggo 多服务插件同时作用于其全部服务实例） */
  private async togglePlugin(rec: InstalledPlugin, on: boolean): Promise<void> {
    if (rec.source === 'manggo') {
      const prefix = `plugin-${rec.pluginId}#`;
      for (const s of settingsStore.getServices()) {
        if (s.id.startsWith(prefix)) {
          await settingsStore.setServiceEnabled(s.id, on);
        }
      }
    } else {
      await settingsStore.setServiceEnabled(pluginServiceId(rec.pluginId), on);
    }
    TranslateUseCase.refreshServices();
    this.bumpPill();
  }

  /** 导入 .bobplugin / .mplugin：系统文件管理器选择 → 校验安装 → 建服务实例（默认启用） */
  private async importPlugin(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const selOpts = new picker.DocumentSelectOptions();
      selOpts.maxSelectNumber = 1;
      selOpts.fileSuffixFilters =
        ['Bob插件(.bobplugin)|.bobplugin', 'Manggo插件(.mplugin)|.mplugin'];
      const dvp = new picker.DocumentViewPicker(this.ctx());
      const uris = await dvp.select(selOpts);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const path = new fileUri.FileUri(uris[0]).path;
      const stat = fileIo.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.readSync(file.fd, buf);
      } finally {
        fileIo.closeSync(file);
      }
      const rec = await PluginInstaller.installFromBytes(this.ctx(), new Uint8Array(buf));
      // 同步登记进引擎管理器：否则下次 rebuild 前建不出 adapter（chip 不出现）
      bobPluginEngine.registerRecord(rec);
      // 重装（升级）场景：强制下次重新加载沙盒代码
      bobPluginEngine.invalidateLoaded(rec.pluginId);
      await this.ensureServiceItem(rec);
      TranslateUseCase.refreshServices();
      this.bumpPill();
      await this.refresh();
      if (rec.source === 'manggo'
        && parseManggoServices(rec.infoJson).filter((s): boolean =>
          isSupportedManggoService(s) && s.kind === 'translation').length > 1) {
        this.toast(`已安装「${rec.name}」，请在插件配置页勾选要在引擎行显示的服务`);
      } else if (rec.category === 'translate') {
        this.toast(`已安装「${rec.name}」，可在引擎行选用`);
      } else {
        this.toast(`已安装「${rec.name}」，可在「我的 → 偏好设置」中选用`);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.toast('导入失败: ' + msg);
    } finally {
      this.importing = false;
    }
  }

  /** 首次导入后建服务实例（默认启用）：
   *  Bob：单实例（id='plugin-<identifier>'，defId='plugin:<identifier>'）；
   *  Manggo：每个受支持服务一个实例（id='plugin-<pid>#<sid>'，defId='plugin:<pid>#<sid>'）。
   *  翻译服务的引擎行勾选（selected）：仅一个翻译服务默认勾选；多个时不勾选任何，
   *  由用户在插件配置页「引擎行显示」勾选（避免导入即铺满全部 chip）。 */
  private async ensureServiceItem(rec: InstalledPlugin): Promise<void> {
    if (rec.source === 'manggo') {
      const list = settingsStore.getServices();
      const services = parseManggoServices(rec.infoJson).filter((s): boolean => isSupportedManggoService(s));
      const transCount = services.filter((s): boolean => s.kind === 'translation').length;
      let changed = false;
      for (const svc of services) {
        const id = manggoServiceId(rec.pluginId, svc.id);
        const hit = list.find((s: ServiceItem): boolean => s.id === id);
        // 显示名：服务 displayName，多服务且未提供时补服务 id 后缀防重名
        const svcName = svc.displayName.length > 0 ? svc.displayName
          : (services.length > 1 ? `${rec.name} · ${svc.id}` : rec.name);
        if (hit === undefined) {
          const item: ServiceItem = {
            id: id,
            defId: manggoDefId(rec.pluginId, svc.id),
            name: svcName,
            enabled: true,
            config: {},
            selected: svc.kind === 'translation' ? transCount <= 1 : undefined
          };
          list.push(item);
          changed = true;
        } else {
          // 重装（升级）场景：同步显示名与勾选默认值，保留开关/配置
          if (hit.name !== svcName) {
            hit.name = svcName;
            changed = true;
          }
          if (svc.kind === 'translation' && hit.selected === undefined) {
            hit.selected = transCount <= 1;
            changed = true;
          }
        }
      }
      if (changed) {
        await settingsStore.setServices(list);
      }
      return;
    }
    const id = pluginServiceId(rec.pluginId);
    if (settingsStore.getService(id) !== undefined) {
      // 重装同名插件：同步显示名，保留开关状态
      const list = settingsStore.getServices();
      const hit = list.find((s: ServiceItem): boolean => s.id === id);
      if (hit !== undefined && hit.name !== rec.name) {
        hit.name = rec.name;
        await settingsStore.setServices(list);
      }
      return;
    }
    const list = settingsStore.getServices();
    const item: ServiceItem = {
      id: id,
      defId: PLUGIN_DEF_PREFIX + rec.pluginId,
      name: rec.name,
      enabled: true,
      config: {}
    };
    list.push(item);
    await settingsStore.setServices(list);
  }

  /** Manggo 多服务插件：配置页目标服务（优先翻译服务，其次首个受支持服务；空串由配置页兜底） */
  private firstServiceId(rec: InstalledPlugin): string {
    const services = parseManggoServices(rec.infoJson).filter((s): boolean => isSupportedManggoService(s));
    if (services.length === 0) {
      return '';
    }
    const translation = services.find((s): boolean => s.kind === 'translation');
    return translation !== undefined ? translation.id : services[0].id;
  }

  /** 删除：二次确认 → 移除服务实例 + 卸载插件 + 重建引擎 */
  private confirmDelete(rec: InstalledPlugin): void {
    AlertDialog.show({
      title: '删除插件',
      message: `删除「${this.displayName(rec)}」？将同时从引擎行移除，需重新导入才能恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Color.White,
        backgroundColor: '#E84026',
        action: () => {
          this.doDelete(rec);
        }
      }
    });
  }

  private async doDelete(rec: InstalledPlugin): Promise<void> {
    // 移除该插件全部服务实例（Bob 单实例；Manggo 多实例带 '#serviceId' 后缀）
    const prefix = `plugin-${rec.pluginId}`;
    for (const s of settingsStore.getServices()) {
      if (s.id === prefix || s.id.startsWith(prefix + '#')) {
        await settingsStore.removeService(s.id);
      }
    }
    await PluginInstaller.uninstall(this.ctx(), rec.pluginId, PluginInstaller.secureAliases(rec));
    bobPluginEngine.invalidate(rec.pluginId);
    TranslateUseCase.refreshServices();
    this.bumpPill();
    await this.refresh();
    this.toast(`已删除「${this.displayName(rec)}」`);
  }

  /** 板块标题 + 插件行列表（仅在该类别有插件时渲染） */
  @Builder
  pluginSection(section: PluginSection) {
    Column() {
      Text(section.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_secondary'))
        .letterSpacing(1)
        .width('100%')
        .margin({ left: 4, bottom: 8 })

      Column() {
        ForEach(this.byCategory(section.category), (rec: InstalledPlugin, idx: number) => {
          Row({ space: 12 }) {
            // 点击行进插件配置页（选项表单 + 测试连通）
            Row({ space: 12 }) {
              Stack() {
                Text(this.displayName(rec).length > 0 ? this.displayName(rec).substring(0, 1) : '插')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .width(40)
                  .height(40)
                  .textAlign(TextAlign.Center)
                  .borderRadius(12)
                  .backgroundColor($r('app.color.brand'))
                if (this.pluginIconUrl(rec) !== '') {
                  Image('file://' + this.pluginIconUrl(rec))
                    .width(40)
                    .height(40)
                    .borderRadius(12)
                    .objectFit(ImageFit.Cover)
                    .onError(() => {
                      this.markIconBroken(rec.pluginId);
                    })
                }
              }
              .width(40)
              .height(40)
              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  Text(this.displayName(rec))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(VerticalAlign.Center)

                // 第二行：来源标识 Bob（蓝）/ Manggo（橘）+ 版本号（长名称不与版本挤同一行）
                Row({ space: 6 }) {
                  Text(sourceLabel(rec))
                    .fontSize(10)
                    .fontColor(rec.source === 'manggo' ? '#E8833A' : $r('app.color.brand'))
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                    .borderRadius(6)
                    .backgroundColor(rec.source === 'manggo' ? '#FBF0E5' : $r('app.color.emphasize_bg_light'))
                  Text('v' + rec.version)
                    .fontSize(10)
                    .fontColor($r('app.color.font_fourth'))
                }
                .alignItems(VerticalAlign.Center)
              }
              .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              const param: Record<string, string> = { 'pluginId': rec.pluginId };
              if (rec.source === 'manggo') {
                param['serviceId'] = this.firstServiceId(rec);
              }
              this.pathStack.pushPath({ name: 'PluginConfigPage', param: param });
            })

            Toggle({ type: ToggleType.Switch, isOn: this.isEnabled(rec) })
              .width(40)
              .height(24)
              .selectedColor($r('app.color.brand'))
              .onChange((on: boolean) => {
                this.togglePlugin(rec, on);
              })

            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(16)
              .fontColor([$r('app.color.font_tertiary')])
              .padding(6)
              .onClick(() => {
                this.confirmDelete(rec);
              })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .alignItems(VerticalAlign.Center)

          if (idx < this.byCategory(section.category).length - 1) {
            Divider()
              .color($r('app.color.divider'))
              .strokeWidth(0.8)
          }
        }, (rec: InstalledPlugin) => rec.pluginId + '_' + rec.version + '_'
          + this.displayName(rec) + (this.isEnabled(rec) ? '_1' : '_0'))
      }
      .width('100%')
      .borderRadius(16)
      .backgroundColor($r('app.color.card_bg'))
      .border({ width: 0.8, color: $r('app.color.divider') })
      .padding({ left: 12, right: 12, top: 4, bottom: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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

          Text('插件服务')
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
            // ── 导入 ──
            Column({ space: 10 }) {
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
                  Text('添加插件')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_primary'))
                  Text('从文件管理器选择 .bobplugin / .mplugin 插件包')
                    .fontSize(12)
                    .lineHeight(17)
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.importing) {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color($r('app.color.brand'))
                } else {
                  SymbolGlyph($r('sys.symbol.plus_circle_fill'))
                    .fontSize(22)
                    .fontColor([$r('app.color.brand')])
                }
              }
              .width('100%')
              .padding(14)
              .alignItems(VerticalAlign.Center)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .opacity(this.importing ? 0.6 : 1)
              .onClick(() => {
                this.importPlugin();
              })

              Text('支持 Bob / Manggo 插件 · 翻译 / 语音TTS / 文字识别OCR · 自动按类型归入下方板块')
                .fontSize(11)
                .fontColor($r('app.color.font_fourth'))
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // ── 三个板块：无相应插件时整体隐藏 ──
            ForEach(SECTIONS, (section: PluginSection) => {
              if (this.byCategory(section.category).length > 0) {
                this.pluginSection(section)
              }
            }, (section: PluginSection) => section.category)

            // ── 空状态 ──
            if (this.plugins.length === 0) {
              Column({ space: 6 }) {
                Text('还没有安装插件')
                  .fontSize(14)
                  .fontColor($r('app.color.font_tertiary'))
                Text('导入 .bobplugin / .mplugin 后自动按类型归入对应板块')
                  .fontSize(11)
                  .fontColor($r('app.color.font_fourth'))
              }
              .width('100%')
              .padding(28)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .alignItems(HorizontalAlign.Center)
            }

            Text('插件在本机沙盒内运行 · 网络请求经由应用统一发起 · 密钥仅保存在本机')
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
