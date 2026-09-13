import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { bobPluginEngine, pluginServiceId } from '../services/plugin/BobPluginEngine';
import { PluginInstaller, InstalledPlugin } from '../services/plugin/PluginInstaller';
import {
  manggoServiceId,
  parseManggoServices,
  parseManggoConfigItems,
  isSupportedManggoService,
  ManggoServiceDef
} from '../services/plugin/ManggoTypes';
import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { TranslateUseCase, TestResult } from '../services/TranslateUseCase';
import { PluginOcrEngine } from '../services/plugin/PluginOcrEngine';
import { PluginTtsPlayback } from '../services/plugin/PluginTtsPlayback';
import { AssetVault } from '../services/AssetVault';
import { PILL_VERSION_KEY } from '../components/EngineSelector';
import pluginHost from 'libpluginhost.so';

/**
 * 插件配置页（NavDestination 二级页，从插件服务页点插件行进入）：
 *  - 名称：可编辑显示名（同步引擎行与插件列表）；
 *  - 选项表单由插件清单驱动，任意数量/组合动态渲染：
 *    Bob info.json options：text → 文本框（textConfig.height ≥ 40 为多行）、menu → 下拉、
 *    textConfig.secure → 密码框（值存 ASSET，别名规则与官方服务商一致）；
 *    Manggo services[].config：text/textarea/password/integer/decimal/select/boolean；
 *  - 保存后 invalidateLoaded：下次翻译自动带新配置重载插件；
 *  - 测试连通：Bob 优先插件自定义 pluginValidate(completion)，未实现回退标准试译；Manggo 直接标准试译。
 */

/** 解析后的插件选项 */
interface PluginOptionItem {
  identifier: string;
  type: string; // text | menu | bool
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
  /** Manggo 多服务插件：目标服务 id（路由参数可选传入；缺省取首个受支持服务） */
  serviceId: string = '';
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @State pluginName: string = '插件设置';
  /** 可编辑显示名（默认 = 清单 name，改后同步引擎行与插件列表） */
  @State displayName: string = '';
  @State options: PluginOptionItem[] = [];
  @State values: Record<string, string> = {};
  @State saving: boolean = false;
  @State testing: boolean = false;
  @State testMsg: string = '';
  /** Manggo 各服务勾选态（serviceId → 启用；翻译=引擎行显示，识别/语音=偏好设置可选） */
  @State serviceOnMap: Record<string, boolean> = {};
  /** Manggo 当前正在编辑配置的服务 id（服务列表高亮） */
  @State activeServiceId: string = '';
  /** 服务图标（serviceId → file:// 路径；无图标不出现在 map） */
  private serviceIconUrls: Record<string, string> = {};
  /** 加载失败的服务图标：回退无图渲染 */
  private brokenIcons: Set<string> = new Set();
  @State iconTick: number = 0;
  /** Manggo 多服务插件标记（配置表单/持久化走 services[].config 约定） */
  private isManggo: boolean = false;
  /** Bob 插件类别（'translate' | 'ocr' | 'tts'）：连通测试按类别走真实调用 */
  private bobKind: string = '';
  /** Manggo：当前服务的 ServiceItem id（'plugin-<pid>#<sid>'）与 defId */
  private serviceItemId: string = '';
  /** Manggo：全部受支持服务（配置页顶部服务切换器数据源） */
  private manggoServices: ManggoServiceDef[] = [];
  /** Manggo：当前服务 kind（'translation' 才显示测试连通） */
  private manggoKind: string = '';
  /** Manggo：identifier → 清单原始 config 项（saveManggoOptionValue 需识别 control 类型） */
  private rawConfigItems: Record<string, Object> = {};

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
    if (rec.source === 'manggo') {
      this.aboutToAppearManggo(rec);
      return;
    }
    this.pluginName = rec.name;
    this.bobKind = rec.category;
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
        // Bob 新版密钥选项标记 isKeyOption：与 textConfig.type=secure 同义（值存 ASSET）
        if (item['isKeyOption'] === true) {
          secure = true;
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

  /** Manggo 多服务插件初始化：解析服务清单 → 定位目标服务 → 装载其配置表单 */
  private aboutToAppearManggo(rec: InstalledPlugin): void {
    this.isManggo = true;
    this.manggoServices = parseManggoServices(rec.infoJson)
      .filter((s): boolean => isSupportedManggoService(s));
    let svc = this.manggoServices.find((s): boolean => s.id === this.serviceId);
    if (svc === undefined && this.manggoServices.length > 0) {
      svc = this.manggoServices[0]; // 未指定服务 id 时取首个受支持服务
    }
    if (svc === undefined) {
      this.toast('插件服务不存在或已删除');
      this.pathStack.pop();
      return;
    }
    this.loadManggoServiceForm(rec, svc);
    this.refreshServiceStates();
    // 服务图标（services[].icon，相对插件目录）：存在才入 map，行内渲染 Image，失败回退无图
    const icons: Record<string, string> = {};
    for (const s of this.manggoServices) {
      if (s.icon.length === 0) {
        continue;
      }
      const p = `${rec.dir}/${s.icon}`;
      try {
        if (fileIo.accessSync(p)) {
          icons[s.id] = 'file://' + p;
        }
      } catch (e) {
        // 忽略：无图标回退
      }
    }
    this.serviceIconUrls = icons;
  }

  /** 当前插件的翻译服务清单（引擎行勾选数据源） */
  private transServices(): ManggoServiceDef[] {
    return this.manggoServices.filter((s): boolean => s.kind === 'translation');
  }

  /** 服务类型徽标文案 */
  private serviceKindLabel(svc: ManggoServiceDef): string {
    if (svc.kind === 'ocr') {
      return '识别';
    }
    if (svc.kind === 'speech') {
      return '语音';
    }
    return svc.resultType === 'dictionary' ? '词典' : '翻译';
  }

  /** 各服务勾选态初始化：翻译服务 selected undefined 按「单翻译默认显示、多翻译默认全隐藏」
   *  归一化并落盘；识别/语音服务默认启用（勾选 = 可在偏好设置中选用）。 */
  private async refreshServiceStates(): Promise<void> {
    const trans = this.transServices();
    const multiTrans = trans.length > 1;
    const list = settingsStore.getServices();
    let changed = false;
    const map: Record<string, boolean> = {};
    for (const svc of this.manggoServices) {
      const itemId = manggoServiceId(this.pluginId, svc.id);
      const hit = list.find((s: ServiceItem): boolean => s.id === itemId);
      if (svc.kind === 'translation') {
        let v = hit !== undefined ? hit.selected : undefined;
        if (v === undefined) {
          v = !multiTrans;
          if (hit !== undefined) {
            hit.selected = v;
            changed = true;
          }
        }
        map[svc.id] = v;
      } else {
        map[svc.id] = hit !== undefined ? hit.enabled : true;
      }
    }
    if (changed) {
      await settingsStore.setServices(list);
      TranslateUseCase.refreshServices();
      AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    }
    this.serviceOnMap = map;
  }

  /** 勾选/取消服务（即时生效）：翻译 = 显示到主页引擎行；识别/语音 = 可在偏好设置中选用 */
  private async onServiceToggle(svc: ManggoServiceDef, on: boolean): Promise<void> {
    const itemId = manggoServiceId(this.pluginId, svc.id);
    const list = settingsStore.getServices();
    const hit = list.find((s: ServiceItem): boolean => s.id === itemId);
    if (hit === undefined) {
      return;
    }
    if (svc.kind === 'translation') {
      hit.selected = on;
    } else {
      hit.enabled = on;
    }
    await settingsStore.setServices(list);
    const map: Record<string, boolean> = {};
    for (const k of Object.keys(this.serviceOnMap)) {
      map[k] = this.serviceOnMap[k];
    }
    map[svc.id] = on;
    this.serviceOnMap = map;
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 切换当前服务（顶部服务选择器；未保存的表单编辑随切换丢弃） */
  private onSwitchManggoService(serviceId: string): void {
    if (serviceId === this.serviceId) {
      return;
    }
    const rec = bobPluginEngine.record(this.pluginId);
    if (rec === undefined) {
      return;
    }
    const svc = this.manggoServices.find((s): boolean => s.id === serviceId);
    if (svc === undefined) {
      return;
    }
    this.loadManggoServiceForm(rec, svc);
  }

  /** 装载指定服务的配置表单与显示名 */
  private loadManggoServiceForm(rec: InstalledPlugin, svc: ManggoServiceDef): void {
    this.serviceId = svc.id;
    this.serviceItemId = manggoServiceId(this.pluginId, svc.id);
    this.manggoKind = svc.kind;
    this.activeServiceId = svc.id;
    this.pluginName = svc.displayName.length > 0 ? svc.displayName : rec.name;
    const serviceList = settingsStore.getServices();
    const svcItem = serviceList.find((s: ServiceItem): boolean => s.id === this.serviceItemId);
    this.displayName = svcItem !== undefined && svcItem.name.length > 0 ? svcItem.name : this.pluginName;
    // 已存配置：ServiceItem.config 镜像（password 项镜像为空串，实际值在 ASSET）
    const stored: Record<string, string> = svcItem !== undefined ? svcItem.config : {};
    const items: PluginOptionItem[] = [];
    const values: Record<string, string> = {};
    for (const item of parseManggoConfigItems(svc.configJson)) {
      const key = typeof item['key'] === 'string' ? item['key'] as string : '';
      if (key === '') {
        continue;
      }
      const control = typeof item['control'] === 'string' ? item['control'] as string : 'text';
      const label = typeof item['label'] === 'string' ? item['label'] as string : key;
      const desc = typeof item['description'] === 'string' ? item['description'] as string : '';
      let placeholder = typeof item['placeholder'] === 'string' ? item['placeholder'] as string : '';
      const secret = control === 'password' || (control === 'text' && item['secret'] === true);
      const menuTitles: string[] = [];
      const menuValues: string[] = [];
      if (control === 'select') {
        const rawOpts = item['options'];
        if (Array.isArray(rawOpts)) {
          for (const o of rawOpts as Array<Object>) {
            if (typeof o !== 'object' || o === null) {
              continue;
            }
            const oo = o as Record<string, Object>;
            const l = typeof oo['label'] === 'string' ? oo['label'] as string : '';
            const v = typeof oo['value'] === 'string' ? oo['value'] as string : l;
            if (l.length > 0) {
              menuTitles.push(l);
              menuValues.push(v);
            }
          }
        }
      }
      // 取值：password → ASSET；其余 → 已存值 → 清单 default
      let value = '';
      if (secret) {
        value = AssetVault.read(`${this.serviceItemId}_${key}`);
      }
      if (value.length === 0) {
        value = stored[key] ?? '';
      }
      if (value.length === 0) {
        const def = item['default'];
        value = typeof def === 'string' ? def as string
          : (typeof def === 'number' || typeof def === 'boolean') ? `${def}` : '';
        if (value.length > 0 && control === 'boolean') {
          value = value === 'true' || def === true ? 'true' : 'false';
        }
      }
      if (control === 'boolean') {
        value = value === 'true' ? 'true' : 'false';
      }
      if (placeholder.length === 0 && menuValues.length === 0 && !secret && control !== 'boolean') {
        placeholder = '请输入' + label;
      }
      items.push({
        identifier: key,
        type: control === 'select' ? 'menu' : (control === 'boolean' ? 'bool' : 'text'),
        title: label,
        desc: desc,
        secure: secret,
        placeholder: placeholder,
        multiline: control === 'textarea',
        menuTitles: menuTitles,
        menuValues: menuValues
      });
      values[key] = value;
      this.rawConfigItems[key] = item;
    }
    this.options = items;
    this.values = values;
  }

  /** 持久化选项与显示名（无提示；保存按钮与测试连通共用） */
  private async persist(): Promise<void> {
    if (this.isManggo) {
      await this.persistManggo();
      return;
    }
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

  /** Manggo：保存服务配置（password → ASSET，其余 → Preferences）+ ServiceItem 镜像与显示名 */
  private async persistManggo(): Promise<void> {
    for (const opt of this.options) {
      const raw = this.rawConfigItems[opt.identifier] as Record<string, Object>;
      if (raw === undefined) {
        continue;
      }
      await PluginInstaller.saveManggoOptionValue(this.ctx(), this.pluginId, this.serviceId,
        raw, this.values[opt.identifier] ?? '');
    }
    // 明文镜像到 ServiceItem.config（password 项存空串占位）
    const plain: Record<string, string> = {};
    for (const opt of this.options) {
      plain[opt.identifier] = opt.secure ? '' : (this.values[opt.identifier] ?? '');
    }
    await settingsStore.updateServiceConfig(this.serviceItemId, plain);
    // 显示名：写入服务 ServiceItem.name
    const newName = this.displayName.trim();
    const list = settingsStore.getServices();
    const hit = list.find((s: ServiceItem): boolean => s.id === this.serviceItemId);
    if (hit !== undefined) {
      const finalName = newName.length > 0 ? newName : hit.name;
      if (hit.name !== finalName) {
        hit.name = finalName;
        await settingsStore.setServices(list);
      }
    }
    if (newName.length > 0 && this.pluginName !== newName) {
      this.pluginName = newName;
    }
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

  /** 测试连通：Bob 优先插件自定义 pluginValidate(completion)，未实现则回退标准试译；
   *  Manggo 直接标准试译（无自定义验证约定）。
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
      if (this.isManggo) {
        const rM: TestResult = await TranslateUseCase.testService(this.serviceItemId);
        this.testMsg = (rM.ok ? '[OK] ' : '[FAIL] ') + rM.message;
        return;
      }
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
        // 插件未实现 pluginValidate：按插件类别回退（翻译→标准试译；OCR/TTS→真实调用）
        if (this.bobKind === 'ocr') {
          this.testMsg = await this.testOcrConnect();
          return;
        }
        if (this.bobKind === 'tts') {
          this.testMsg = await this.testTtsConnect();
          return;
        }
        const r: TestResult = await TranslateUseCase.testService(pluginServiceId(this.pluginId));
        this.testMsg = (r.ok ? '[OK] ' : '[FAIL] ') + r.message;
      }
    } finally {
      this.testing = false;
    }
  }

  /** 1×1 白色 PNG（OCR 连通测试用）：无文字可识别是预期，「未识别到文字」也算连通 */
  private static readonly TINY_PNG_B64: string =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC';

  /** OCR 插件连通测试：真实调用一次 OCR（1×1 图片）；「未识别到文字」说明模型可达，视为通过 */
  private async testOcrConnect(): Promise<string> {
    try {
      await PluginOcrEngine.recognize(this.pluginId, PluginConfigPage.TINY_PNG_B64, 'auto', 1, 1);
      return '[OK] 连通正常（插件 OCR 调用成功）';
    } catch (e) {
      const msg = (e instanceof Error) ? e.message : String(e);
      if (msg.indexOf('未识别到文字') >= 0) {
        return '[OK] 连通正常（模型可达，图片无文字）';
      }
      return '[FAIL] ' + msg;
    }
  }

  /** TTS 插件连通测试：合成一段短语音后立即停止，不播放 */
  private async testTtsConnect(): Promise<string> {
    try {
      const pb = await PluginTtsPlayback.speak(this.ctx(), this.pluginId, '连通测试', 'zh-CN',
        (): void => {});
      try {
        await pb.stop();
      } catch (e) {
        // 已停止等场景忽略
      }
      return '[OK] 连通正常（语音合成成功，未播放）';
    } catch (e) {
      return '[FAIL] ' + ((e instanceof Error) ? e.message : String(e));
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
            // ── 服务（Manggo：勾选启用服务；点按行切换下方配置表单） ──
            if (this.isManggo && this.manggoServices.length >= 1) {
              Column({ space: 4 }) {
                Text('服务')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_primary'))
                  .width('100%')
                Text('勾选启用服务；点按服务行在下方编辑其配置（切换会丢弃未保存的修改）')
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
                  .width('100%')
                ForEach(this.manggoServices, (svc: ManggoServiceDef) => {
                  Row({ space: 10 }) {
                    Checkbox({ name: svc.id })
                      .select(this.serviceOnMap[svc.id] === true)
                      .selectedColor($r('app.color.brand'))
                      .width(20)
                      .height(20)
                      .onChange((on: boolean) => {
                        this.onServiceToggle(svc, on);
                      })
                    if (this.serviceIconUrls[svc.id] !== undefined
                      && !this.brokenIcons.has(svc.id)) {
                      Image(this.serviceIconUrls[svc.id])
                        .width(26)
                        .height(26)
                        .borderRadius(7)
                        .objectFit(ImageFit.Cover)
                        .onError(() => {
                          this.brokenIcons.add(svc.id);
                          this.iconTick++;
                        })
                    }
                    Row({ space: 8 }) {
                      Text(svc.displayName.length > 0 ? svc.displayName : svc.id)
                        .fontSize(14)
                        .fontColor($r('app.color.font_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Blank()
                      Text(this.serviceKindLabel(svc))
                        .fontSize(10)
                        .fontColor($r('app.color.font_fourth'))
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .borderRadius(6)
                        .backgroundColor($r('app.color.emphasize_bg_light'))
                    }
                    .layoutWeight(1)
                    .alignItems(VerticalAlign.Center)
                    .onClick(() => {
                      this.onSwitchManggoService(svc.id);
                    })
                  }
                  .width('100%')
                  .padding({ left: 8, right: 8, top: 9, bottom: 9 })
                  .borderRadius(10)
                  .backgroundColor(this.activeServiceId === svc.id
                    ? $r('app.color.emphasize_bg_light') : Color.Transparent)
                  .alignItems(VerticalAlign.Center)
                }, (svc: ManggoServiceDef) => svc.id)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
            }

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
              Text(this.isManggo ? '当前服务的显示名（引擎行 / 服务列表）' : '显示在主页引擎行与插件服务列表')
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
                    } else if (opt.type === 'bool') {
                      // Manggo boolean 控件：开关（值以 'true'/'false' 存储）
                      Row() {
                        Blank()
                        Toggle({ type: ToggleType.Switch, isOn: this.values[opt.identifier] === 'true' })
                          .width(40)
                          .height(24)
                          .selectedColor($r('app.color.brand'))
                          .onChange((on: boolean) => {
                            this.values[opt.identifier] = on ? 'true' : 'false';
                          })
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
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
                Text(this.isManggo ? '当前服务没有可配置项' : '此插件没有可配置项')
                  .fontSize(14)
                  .fontColor($r('app.color.font_tertiary'))
                Text(this.isManggo ? '可在上方服务列表点按其他服务分别配置' : '安装后即可在引擎行直接使用')
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

            // ── 测试连通（仅翻译服务；TTS/OCR 服务无标准试译路径） ──
            if (!this.isManggo || this.manggoKind === 'translation') {
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
