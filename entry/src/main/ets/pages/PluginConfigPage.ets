import { common } from '@kit.AbilityKit';
import { bobPluginEngine, pluginServiceId } from '../services/plugin/BobPluginEngine';
import { PluginInstaller, InstalledPlugin } from '../services/plugin/PluginInstaller';
import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { TranslateUseCase, TestResult } from '../services/TranslateUseCase';
import { AssetVault } from '../services/AssetVault';
import { PILL_VERSION_KEY } from '../components/EngineSelector';
import pluginHost from 'libpluginhost.so';

/**
 * 插件配置页（NavDestination 二级页，从插件服务页点插件行进入）：
 *  - 名称：可编辑显示名（同步引擎行与插件列表）；
 *  - 选项表单由插件 info.json 的 options 驱动，任意数量/组合动态渲染：
 *    text → 文本框（textConfig.height ≥ 40 为多行）、menu → 下拉、
 *    textConfig.secure → 密码框（值存 ASSET，别名规则与官方服务商一致）；
 *  - 保存后 invalidateLoaded：下次翻译自动带新配置重载插件；
 *  - 测试连通：优先调用插件自定义 pluginValidate(completion)，未实现则回退标准试译。
 */

/** 解析后的插件选项 */
interface PluginOptionItem {
  identifier: string;
  type: string; // text | menu
  title: string;
  desc: string;
  secure: boolean;
  placeholder: string;
  multiline: boolean;
  menuTitles: string[];
  menuValues: string[];
}

@Component
export struct PluginConfigPage {
  pluginId: string = '';
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @State pluginName: string = '插件设置';
  /** 可编辑显示名（默认 = info.json name，改后同步引擎行与插件列表） */
  @State displayName: string = '';
  @State options: PluginOptionItem[] = [];
  @State values: Record<string, string> = {};
  @State saving: boolean = false;
  @State testing: boolean = false;
  @State testMsg: string = '';

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  aboutToAppear(): void {
    const rec: InstalledPlugin | undefined = bobPluginEngine.record(this.pluginId);
    if (rec === undefined) {
      this.toast('插件不存在或已删除');
      this.pathStack.pop();
      return;
    }
    this.pluginName = rec.name;
    const svc = settingsStore.getService(pluginServiceId(this.pluginId));
    // 显示名：用户改过用改名，否则用插件默认名
    this.displayName = svc !== undefined && svc.name.length > 0 ? svc.name : rec.name;
    // 解析 options 并初始化取值：secure → ASSET；其余 → ServiceItem.config → defaultValue
    const stored: Record<string, string> = svc !== undefined ? svc.config : ((): Record<string, string> => {
      const empty: Record<string, string> = {};
      return empty;
    })();
    const items: PluginOptionItem[] = [];
    const values: Record<string, string> = {};
    try {
      const info = JSON.parse(rec.infoJson) as Record<string, Object>;
      const rawOptions = info['options'];
      const list = Array.isArray(rawOptions) ? rawOptions as Array<Record<string, Object>> : [];
      for (const item of list) {
        const id = typeof item['identifier'] === 'string' ? item['identifier'] as string : '';
        if (id === '') {
          continue;
        }
        const type = typeof item['type'] === 'string' ? item['type'] as string : 'text';
        const menuTitles: string[] = [];
        const menuValues: string[] = [];
        const rawMenus = item['menuValues'];
        if (Array.isArray(rawMenus)) {
          for (const m of rawMenus as Array<Object>) {
            const mo = m as Record<string, Object>;
            const mt = typeof mo['title'] === 'string' ? mo['title'] as string : '';
            const mv = typeof mo['value'] === 'string' ? mo['value'] as string : mt;
            menuTitles.push(mt);
            menuValues.push(mv);
          }
        }
        let secure = false;
        let placeholder = '';
        let multiline = false;
        const tc = item['textConfig'];
        if (typeof tc === 'object' && tc !== null && !Array.isArray(tc)) {
          const tco = tc as Record<string, Object>;
          secure = tco['type'] === 'secure';
          const ph = tco['placeholderText'];
          if (typeof ph === 'string') {
            placeholder = ph;
          }
          const h = tco['height'];
          if (typeof h === 'number' && h >= 40) {
            multiline = true;
          }
        }
        let value = '';
        if (secure) {
          value = AssetVault.read(`${pluginServiceId(this.pluginId)}_${id}`);
        }
        if (value.length === 0) {
          value = stored[id] ?? '';
        }
        if (value.length === 0) {
          const def = typeof item['defaultValue'] === 'string' ? item['defaultValue'] as string : '';
          value = def;
        }
        items.push({
          identifier: id,
          type: type,
          title: typeof item['title'] === 'string' ? item['title'] as string : id,
          desc: typeof item['desc'] === 'string' ? item['desc'] as string : '',
          secure: secure,
          placeholder: placeholder,
          multiline: multiline,
          menuTitles: menuTitles,
          menuValues: menuValues
        });
        values[id] = value;
      }
    } catch (e) {
      this.toast('插件配置解析失败');
    }
    this.options = items;
    this.values = values;
  }

  /** 持久化选项与显示名（无提示；保存按钮与测试连通共用） */
  private async persist(): Promise<void> {
    for (const opt of this.options) {
      await PluginInstaller.saveOptionValue(this.ctx(), this.pluginId, this.toRawItem(opt), this.values[opt.identifier]);
    }
    // 旧版明文兜底：配置值同步一份到 ServiceItem.config（secure 项存空串占位）
    const plain: Record<string, string> = {};
    for (const opt of this.options) {
      plain[opt.identifier] = opt.secure ? '' : (this.values[opt.identifier] ?? '');
    }
    await settingsStore.updateServiceConfig(pluginServiceId(this.pluginId), plain);
    // 显示名：写入 ServiceItem.name（空则回退插件默认名）
    const rec = bobPluginEngine.record(this.pluginId);
    const newName = this.displayName.trim();
    const list = settingsStore.getServices();
    const hit = list.find((s: ServiceItem): boolean => s.id === pluginServiceId(this.pluginId));
    if (hit !== undefined) {
      const finalName = newName.length > 0 ? newName : (rec !== undefined ? rec.name : hit.name);
      if (hit.name !== finalName) {
        hit.name = finalName;
        await settingsStore.setServices(list);
      }
    }
    if (rec !== undefined && newName.length > 0 && rec.name !== newName) {
      rec.name = newName; // 同步内存登记，插件服务页列表立即可见
    }
    // 下次翻译带新配置重载插件；引擎行标签（可能因改名）刷新
    bobPluginEngine.invalidateLoaded(this.pluginId);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      await this.persist();
      this.toast('已保存');
    } catch (e) {
      this.toast('保存失败: ' + ((e instanceof Error) ? e.message : String(e)));
    } finally {
      this.saving = false;
    }
  }

  /** 回传 info.json 原始选项对象（saveOptionValue 需要识别 secure） */
  private toRawItem(opt: PluginOptionItem): Record<string, Object> {
    const rec = bobPluginEngine.record(this.pluginId);
    if (rec !== undefined) {
      try {
        const info = JSON.parse(rec.infoJson) as Record<string, Object>;
        const rawOptions = info['options'];
        const list = Array.isArray(rawOptions) ? rawOptions as Array<Record<string, Object>> : [];
        for (const item of list) {
          if (item['identifier'] === opt.identifier) {
            return item;
          }
        }
      } catch (e) {
        // 落入下方合成
      }
    }
    const synth: Record<string, Object> = {
      'identifier': opt.identifier, 'type': opt.type, 'title': opt.title
    };
    if (opt.secure) {
      synth['textConfig'] = { 'type': 'secure' } as Record<string, string>;
    }
    return synth;
  }

  /** 测试连通：优先插件自定义 pluginValidate(completion)，未实现则回退标准试译。
   *  必须先 ensureLoaded（含 initRuntime）：运行时未启动时 callPluginFn 无人消费会永久挂起。 */
  private async testPlugin(): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testing = true;
    this.testMsg = '';
    try {
      await this.persist(); // 静默保存，不弹“已保存”
      await bobPluginEngine.ensureLoaded(this.pluginId);
      try {
        const raw = await pluginHost.callPluginFn(this.pluginId, 'pluginValidate', '[]', 'callback', 15000);
        const parsed = JSON.parse(raw) as Record<string, Object>;
        const ok = parsed['result'] === true;
        let msg = ok ? '验证通过' : '验证未通过';
        const errObj = parsed['error'];
        if (!ok && errObj !== undefined && errObj !== null) {
          const eo = errObj as Record<string, Object>;
          if (typeof eo['message'] === 'string') {
            msg = eo['message'] as string;
          }
        }
        this.testMsg = (ok ? '[OK] ' : '[FAIL] ') + msg;
      } catch (e) {
        // 插件未实现 pluginValidate：回退标准试译
        const r: TestResult = await TranslateUseCase.testService(pluginServiceId(this.pluginId));
        this.testMsg = (r.ok ? '[OK] ' : '[FAIL] ') + r.message;
      }
    } finally {
      this.testing = false;
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

          Text(this.pluginName)
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

        Scroll() {
          Column({ space: 12 }) {
            // ── 名称 ──
            Column({ space: 6 }) {
              Text('名称')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
                .width('100%')
              TextInput({ text: this.displayName })
                .fontSize(14)
                .height(42)
                .width('100%')
                .backgroundColor($r('app.color.bg_page'))
                .onChange((v: string) => {
                  this.displayName = v;
                })
              Text('显示在主页引擎行与插件服务列表')
                .fontSize(11)
                .fontColor($r('app.color.font_fourth'))
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })

            // ── 选项表单（由 info.json options 动态渲染） ──
            if (this.options.length > 0) {
              Column({ space: 4 }) {
                ForEach(this.options, (opt: PluginOptionItem) => {
                  Column({ space: 6 }) {
                    Text(opt.title)
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.font_primary'))
                      .width('100%')
                    if (opt.desc.length > 0) {
                      Text(opt.desc)
                        .fontSize(11)
                        .fontColor($r('app.color.font_tertiary'))
                        .width('100%')
                    }
                    if (opt.type === 'menu' && opt.menuValues.length > 1) {
                      Select(this.menuSelectOptions(opt))
                        .selected(this.menuSelectedIdx(opt))
                        .value(this.menuDisplayValue(opt))
                        .fontColor($r('app.color.font_primary'))
                        .font({ size: 14 })
                        .optionFont({ size: 14 })
                        .width('100%')
                        .onSelect((idx: number): void => {
                          if (idx >= 0 && idx < opt.menuValues.length) {
                            this.values[opt.identifier] = opt.menuValues[idx];
                          }
                        })
                    } else if (opt.type === 'menu') {
                      // 单值菜单（插件作者常用来放说明文字）：按静态文本展示，值保持默认
                      Text(this.menuDisplayValue(opt))
                        .fontSize(14)
                        .fontColor($r('app.color.font_secondary'))
                        .width('100%')
                        .padding({ top: 4, bottom: 4 })
                    } else if (opt.secure) {
                      TextInput({ text: this.values[opt.identifier], placeholder: opt.placeholder })
                        .type(InputType.Password)
                        .fontSize(14)
                        .height(42)
                        .width('100%')
                        .backgroundColor($r('app.color.bg_page'))
                        .onChange((v: string) => {
                          this.values[opt.identifier] = v;
                        })
                    } else if (opt.multiline) {
                      TextArea({ text: this.values[opt.identifier], placeholder: opt.placeholder })
                        .fontSize(14)
                        .height(88)
                        .width('100%')
                        .backgroundColor($r('app.color.bg_page'))
                        .onChange((v: string) => {
                          this.values[opt.identifier] = v;
                        })
                    } else {
                      TextInput({ text: this.values[opt.identifier], placeholder: opt.placeholder })
                        .fontSize(14)
                        .height(42)
                        .width('100%')
                        .backgroundColor($r('app.color.bg_page'))
                        .onChange((v: string) => {
                          this.values[opt.identifier] = v;
                        })
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding({ top: 10, bottom: 10 })

                  if (opt.identifier !== this.options[this.options.length - 1].identifier) {
                    Divider()
                      .color($r('app.color.divider'))
                      .strokeWidth(0.8)
                  }
                }, (opt: PluginOptionItem) => opt.identifier)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .alignItems(HorizontalAlign.Start)
            } else {
              Column({ space: 6 }) {
                Text('此插件没有可配置项')
                  .fontSize(14)
                  .fontColor($r('app.color.font_tertiary'))
                Text('安装后即可在引擎行直接使用')
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

            // ── 操作 ──（原生等待态：Button 内嵌 LoadingProgress）
            Button() {
              Row({ space: 8 }) {
                if (this.saving) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color($r('sys.color.ohos_id_color_text_primary_contrary'))
                }
                Text(this.saving ? '保存中' : '保存')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
              }
              .alignItems(VerticalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .height('100%')
            }
            .width('100%')
            .height(42)
            .borderRadius(21)
            .backgroundColor($r('app.color.brand'))
            .enabled(!this.saving)
            .onClick(() => {
              this.save();
            })

            Button() {
              Row({ space: 8 }) {
                if (this.testing) {
                  LoadingProgress()
                    .width(16)
                    .height(16)
                    .color($r('app.color.brand'))
                }
                Text(this.testing ? '测试中' : '测试连通')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.brand'))
              }
              .alignItems(VerticalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .height('100%')
            }
            .width('100%')
            .height(42)
            .borderRadius(21)
            .backgroundColor($r('app.color.emphasize_bg_light'))
            .enabled(!this.testing)
            .onClick(() => {
              this.testPlugin();
            })

            if (this.testMsg.length > 0) {
              Text(this.testMsg)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor(this.testMsg.startsWith('[OK]') ? $r('app.color.confirm') : $r('app.color.font_secondary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }

            Text('密钥类配置加密存储在本机 · 保存后下次翻译自动生效')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
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
  }

  /** Select 组件选项 */
  private menuSelectOptions(opt: PluginOptionItem): SelectOption[] {
    const out: SelectOption[] = [];
    for (const t of opt.menuTitles) {
      out.push({ value: t });
    }
    return out;
  }

  private menuSelectedIdx(opt: PluginOptionItem): number {
    const idx = opt.menuValues.indexOf(this.values[opt.identifier] ?? '');
    return idx >= 0 ? idx : 0;
  }

  private menuDisplayValue(opt: PluginOptionItem): string {
    const idx = opt.menuValues.indexOf(this.values[opt.identifier] ?? '');
    return idx >= 0 ? opt.menuTitles[idx] : (this.values[opt.identifier] ?? opt.menuTitles[0] ?? '');
  }
}
