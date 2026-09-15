/**
 * 我的页：纯入口列表——「翻译服务」行进入服务管理页（ServicesPage），
 * 偏好设置（默认引擎/语言对/深色模式）与「关于」卡（隐私政策/用户反馈交流/关于鸿译）保留在本页。
 * 沉浸式：顶部避让状态栏（由 Index 包裹层处理），底部避让手势条。
 */

import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { settingsStore } from '../services/SettingsStore';
import { EngineRegistry } from '../services/EngineRegistry';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { BackupService, BackupPayload } from '../services/BackupService';
import { PasswordDialog } from '../components/PasswordDialog';
import { AUTO_DETECT, LANGUAGE_LIST, LanguageItem, LangCode } from '../models/TranslationTypes';
import { Ux } from '../common/Ux';
import { APP_VERSION } from './AboutPage';
import { PILL_VERSION_KEY } from '../components/EngineSelector';
import { PluginInstaller, InstalledPlugin } from '../services/plugin/PluginInstaller';
import { parseManggoServices } from '../services/plugin/ManggoTypes';

interface EngineOption {
  id: string;
  label: string;
}

/** TTS/OCR 服务选项：'system' + 各插件服务实例（Bob 单实例；Manggo 每服务一实例） */
interface PluginEngineOption {
  /** 引擎 id：'plugin-<pid>'（Bob）| 'plugin-<pid>#<sid>'（Manggo） */
  engineId: string;
  label: string;
}

@Component
export struct SettingsPageContent {
  /** 页签序号；切到「我的」时重读偏好（规避启动时 bootstrap 未完成的一次性读值竞态） */
  @Link @Watch('onTabChanged') currentIndex: number;
  /** 路由栈（Index Navigation 提供），用于跳转翻译服务页 */
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 插件变更广播（导入/开关/删除时 bump）：驱动 TTS/OCR Select 选项实时刷新 */
  @StorageProp(PILL_VERSION_KEY) @Watch('onPluginsMutated') pillVersion: number = 0;
  /** 窗口宽度（vp）：≥600 判定宽屏，内容限宽居中 */
  @StorageProp('ux_winW') winW: number = 0;
  @State engineId: string = 'edge';
  @State fromLang: string = AUTO_DETECT;
  @State toLang: string = 'en';
  @State colorModePref: string = 'system';
  /** 语音服务 TTS / 文字识别 OCR 服务选择（'system' = 系统服务） */
  @State ttsEngineId: string = 'system';
  @State ocrEngineId: string = 'system';
  /** TTS/OCR 服务选项（Select 选项来源；含 Manggo 多服务插件的逐服务实例） */
  @State ttsPlugins: PluginEngineOption[] = [];
  @State ocrPlugins: PluginEngineOption[] = [];
  /** 拍照翻译：照片是否保存到相册（默认不保存，识别后即删） */
  @State ocrSaveGallery: boolean = false;
  /** 备份/恢复进行中（防重复点击） */
  @State backupBusy: boolean = false;
  /** 上次备份时间戳（0=从未） */
  @State lastBackupAt: number = 0;
  /** 待恢复的备份文件字节（选文件成功后暂存，输入密码后解密应用） */
  private pendingRestoreBytes: Uint8Array | null = null;
  /** 备份弹窗（密码可选 + 「包含已安装插件」可选项） */
  backupPwdController: CustomDialogController = new CustomDialogController({
    builder: PasswordDialog({
      title: '备份选项',
      confirmText: '开始备份',
      passwordOptional: true,
      showPluginOption: true,
      onConfirm: (password: string, includePlugins: boolean): void => {
        this.doBackup(password, includePlugins);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center
  });
  /** 恢复密码弹窗（仅有密码的备份文件会弹出；无密码文件直接解密） */
  restorePwdController: CustomDialogController = new CustomDialogController({
    builder: PasswordDialog({
      title: '输入备份密码',
      confirmText: '解密恢复',
      onConfirm: (password: string, _includePlugins: boolean): void => {
        this.doRestoreDecrypt(password);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear(): void {
    const eng = settingsStore.getEngineId();
    if (eng !== undefined && eng.length > 0) {
      this.engineId = eng;
    }
    const f = settingsStore.getFromLang();
    if (f !== undefined && f.length > 0) {
      this.fromLang = f;
    }
    const t = settingsStore.getToLang();
    if (t !== undefined && t.length > 0) {
      this.toLang = t;
    }
    const cm = settingsStore.getColorModePref();
    if (cm !== undefined && cm.length > 0) {
      this.colorModePref = cm;
    }
    this.ocrSaveGallery = settingsStore.getOcrSaveToGallery();
    this.lastBackupAt = BackupService.lastBackupAt();
    this.ttsEngineId = settingsStore.getTtsEngineId();
    this.ocrEngineId = settingsStore.getOcrEngineId();
    this.refreshPluginEngines();
    AppStorage.setOrCreate('pref_to_lang', this.toLang);
  }

  /** 刷新 TTS/OCR 服务选项：本机添加的云端服务实例（已启用）+ 已启用插件服务。
   *  Bob 单实例（'plugin-<pid>'）；Manggo 逐服务实例（'plugin-<pid>#<sid>'）。
   *  当前选中的服务若被停用/删除，自动回退系统服务。 */
  private refreshPluginEngines(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    PluginInstaller.list(ctx).then((list: InstalledPlugin[]): void => {
      const buildOptions = (manggoKind: string, bobCategory: string): PluginEngineOption[] => {
        const out: PluginEngineOption[] = [];
        for (const p of list) {
          if (p.source === 'manggo') {
            for (const svc of parseManggoServices(p.infoJson)) {
              if (svc.kind !== manggoKind) {
                continue;
              }
              const engineId = `plugin-${p.pluginId}#${svc.id}`;
              const svcItem = settingsStore.getService(engineId);
              if (svcItem !== undefined && svcItem.enabled) {
                const label = svcItem.name.length > 0 ? svcItem.name
                  : (svc.displayName.length > 0 ? svc.displayName : p.name);
                out.push({ engineId: engineId, label: label });
              }
            }
            continue;
          }
          if (p.category !== bobCategory) {
            continue;
          }
          const svcBob = settingsStore.getService('plugin-' + p.pluginId);
          if (svcBob !== undefined && svcBob.enabled) {
            out.push({
              engineId: 'plugin-' + p.pluginId,
              label: svcBob.name.length > 0 ? svcBob.name : p.name
            });
          }
        }
        return out;
      };
      // 本机添加的云端服务实例（服务管理页添加，已启用才进选项；实例 id 与 'system'/'plugin-' 天然可区分）
      const nativeTts: PluginEngineOption[] = [];
      for (const s of settingsStore.getTtsServices()) {
        if (s.enabled) {
          nativeTts.push({ engineId: s.id, label: s.name });
        }
      }
      const nativeOcr: PluginEngineOption[] = [];
      for (const s of settingsStore.getOcrServices()) {
        if (s.enabled) {
          nativeOcr.push({ engineId: s.id, label: s.name });
        }
      }
      this.ttsPlugins = nativeTts.concat(buildOptions('speech', 'tts'));
      this.ocrPlugins = nativeOcr.concat(buildOptions('ocr', 'ocr'));
      // 选中项被停用/删除（插件或本机实例）→ 回退系统服务
      if (this.ttsEngineId !== 'system'
        && !this.ttsPlugins.some((o: PluginEngineOption): boolean => o.engineId === this.ttsEngineId)) {
        this.ttsEngineId = 'system';
        settingsStore.setTtsEngineId('system');
      }
      if (this.ocrEngineId !== 'system'
        && !this.ocrPlugins.some((o: PluginEngineOption): boolean => o.engineId === this.ocrEngineId)) {
        this.ocrEngineId = 'system';
        settingsStore.setOcrEngineId('system');
      }
    }).catch((e: Object): void => {
      // 清单读取失败保持本机服务选项（插件选项置空，仅系统+本机服务可选）
      const nativeTts: PluginEngineOption[] = [];
      for (const s of settingsStore.getTtsServices()) {
        if (s.enabled) {
          nativeTts.push({ engineId: s.id, label: s.name });
        }
      }
      const nativeOcr: PluginEngineOption[] = [];
      for (const s of settingsStore.getOcrServices()) {
        if (s.enabled) {
          nativeOcr.push({ engineId: s.id, label: s.name });
        }
      }
      this.ttsPlugins = nativeTts;
      this.ocrPlugins = nativeOcr;
    });
  }

  /** TTS/OCR Select 选项：系统服务 + 已启用插件服务 */
  private serviceOptions(plugins: PluginEngineOption[]): SelectOption[] {
    const opts: SelectOption[] = [{ value: '系统服务' }];
    for (const o of plugins) {
      opts.push({ value: o.label });
    }
    return opts;
  }

  private serviceSelectedIndex(id: string, plugins: PluginEngineOption[]): number {
    const idx = plugins.findIndex((o: PluginEngineOption): boolean => o.engineId === id);
    return idx >= 0 ? idx + 1 : 0;
  }

  private serviceSelectedLabel(id: string, plugins: PluginEngineOption[]): string {
    const hit = plugins.find((o: PluginEngineOption): boolean => o.engineId === id);
    return hit !== undefined ? hit.label : '系统服务';
  }

  private pickTtsEngine(id: string): void {
    this.ttsEngineId = id;
    settingsStore.setTtsEngineId(id);
    const label = id === 'system' ? '系统服务' : this.serviceSelectedLabel(id, this.ttsPlugins);
    this.toast('语音服务已设为 ' + label);
  }

  private pickOcrEngine(id: string): void {
    this.ocrEngineId = id;
    settingsStore.setOcrEngineId(id);
    const label = id === 'system' ? '系统服务' : this.serviceSelectedLabel(id, this.ocrPlugins);
    this.toast('文字识别已设为 ' + label);
  }

  /** 每次切到「我的」页签都重读偏好：启动瞬间 bootstrap 可能未完成，首帧读值不可靠 */
  private onTabChanged(): void {
    if (this.currentIndex === 2) {
      this.reloadPrefs();
    }
  }

  /** 插件变更（导入/启用停用/删除）后刷新 TTS/OCR Select 选项 */
  private onPluginsMutated(): void {
    if (this.currentIndex === 2) {
      this.refreshPluginEngines();
    }
  }

  private pickDefaultEngine(id: string): void {
    this.engineId = id;
    settingsStore.setEngineId(id);
    AppStorage.setOrCreate('pref_engine_id', id);
    this.getUIContext().getPromptAction().showToast({ message: '默认引擎已设为 ' + this.engineLabel(id) });
  }

  private setLang(from: LangCode, to: LangCode): void {
    this.fromLang = from;
    this.toLang = to;
    settingsStore.setFromLang(from);
    settingsStore.setToLang(to);
    AppStorage.setOrCreate('pref_from_lang', from);
    AppStorage.setOrCreate('pref_to_lang', to);
  }

  private applyColorMode(mode: string): void {
    this.colorModePref = mode;
    settingsStore.setColorModePref(mode);
    const ctx = getContext(this).getApplicationContext();
    if (mode === 'dark') {
      ctx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } else if (mode === 'light') {
      ctx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } else {
      ctx.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }
    Ux.applySystemBarStyle(mode === 'dark' || (mode === 'system' && Ux.systemDark));
  }

  private engineLabel(id: string): string {
    const hit = EngineRegistry.byId(id);
    return hit !== undefined ? hit.label : id;
  }

  private fromItems(): LanguageItem[] {
    const list: LanguageItem[] = [{ code: AUTO_DETECT, label: '自动检测' }];
    for (const it of LANGUAGE_LIST) {
      list.push({ code: it.code, label: it.label });
    }
    return list;
  }

  private indexOfFrom(): number {
    const idx = this.fromItems().findIndex((it: LanguageItem): boolean => it.code === this.fromLang);
    return idx >= 0 ? idx : 0;
  }

  private indexOfTo(): number {
    const idx = LANGUAGE_LIST.findIndex((it): boolean => it.code === this.toLang);
    return idx >= 0 ? idx : 0;
  }

  private langLabelOf(code: LangCode): string {
    if (code === AUTO_DETECT) {
      return '自动检测';
    }
    const hit = LANGUAGE_LIST.find((it): boolean => it.code === code);
    return hit !== undefined ? hit.label : code;
  }

  private colorModeIndex(): number {
    return this.colorModePref === 'dark' ? 2 : (this.colorModePref === 'light' ? 1 : 0);
  }

  private colorModeLabel(): string {
    return this.colorModePref === 'dark' ? '深色' : (this.colorModePref === 'light' ? '浅色' : '跟随系统');
  }

  private openServices(): void {
    this.pathStack.pushPath({ name: 'ServicesPage' });
  }

  // ---- 备份与恢复 ----

  private errText(e: Object): string {
    const be = e as BusinessError;
    if (be !== null && be !== undefined && be.code !== undefined) {
      return be.code + ' ' + (be.message ?? '');
    }
    if (e instanceof Error) {
      return e.message.length > 0 ? e.message : String(e);
    }
    return String(e);
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private openBackupDialog(): void {
    if (this.backupBusy) {
      return;
    }
    this.backupPwdController.open();
  }

  /** 弹窗收集密码/插件勾选后：收集数据 → 加密 → 写 Download/<包名>/ */
  private async doBackup(password: string, includePlugins: boolean): Promise<void> {
    if (this.backupBusy || (password.length > 0 && password.length < 4)) {
      return;
    }
    this.backupBusy = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const fileName = await BackupService.backup(ctx, password, includePlugins);
      if (fileName.length === 0) {
        return; // 用户取消
      }
      this.lastBackupAt = BackupService.lastBackupAt();
      this.toast('已备份到 Download/鸿译 目录：' + fileName);
    } catch (e) {
      this.toast('备份失败：' + this.errText(e));
    } finally {
      this.backupBusy = false;
    }
  }

  /** 先拉系统文件管理器选 .htrans 文件；无密码备份直接解密，有密码弹密码框 */
  private async openRestore(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const bytes = await BackupService.pickBackupFile(ctx);
      if (bytes === null) {
        return; // 用户取消
      }
      this.pendingRestoreBytes = bytes;
      const head = BackupService.peekHeader(bytes);
      if (head.valid && !head.hasPassword) {
        await this.doRestoreDecrypt('');
        return;
      }
      this.restorePwdController.open();
    } catch (e) {
      this.toast('读取备份文件失败：' + this.errText(e));
    }
  }

  /** 密码就绪：解密校验 → 二选确认（合并/覆盖；点弹窗外=取消）→ 应用 */
  private async doRestoreDecrypt(password: string): Promise<void> {
    const bytes = this.pendingRestoreBytes;
    if (bytes === null || this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    let payload: BackupPayload | null = null;
    try {
      payload = await BackupService.parse(bytes, password);
    } catch (e) {
      const msg = this.errText(e);
      this.toast(msg.includes('17630001') ? '密码错误或备份文件已损坏' : msg);
    } finally {
      this.backupBusy = false;
    }
    if (payload === null) {
      return;
    }
    const info = BackupService.describe(payload);
    this.getUIContext().showAlertDialog({
      title: '确认恢复',
      message: info + '\n\n「合并」保留现有历史并去重导入；「覆盖」会清空现有历史与服务商配置后恢复。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '合并恢复',
        fontColor: $r('app.color.brand'),
        action: (): void => {
          this.doApplyRestore(payload!, false);
        }
      },
      secondaryButton: {
        value: '覆盖恢复',
        fontColor: $r('app.color.warning'),
        action: (): void => {
          this.doApplyRestore(payload!, true);
        }
      }
    });
  }

  private async doApplyRestore(payload: BackupPayload, replace: boolean): Promise<void> {
    try {
      const summary = await BackupService.apply(payload, replace, getContext(this) as common.Context);
      this.reloadPrefs();
      const hist = summary.historyReplaced
        ? '已覆盖恢复 ' + summary.historyAdded + ' 条历史'
        : '已合并 ' + summary.historyAdded + ' 条历史';
      let msg = hist + ' · 服务商 ' + summary.serviceCount + ' 个';
      if (summary.pluginCount > 0) {
        msg += ' · 插件 ' + summary.pluginCount + ' 个';
      }
      this.toast(msg);
    } catch (e) {
      this.toast('恢复失败：' + this.errText(e));
    } finally {
      this.backupBusy = false;
      this.pendingRestoreBytes = null;
    }
  }

  /** 恢复/切页签后重读本页全部偏好 */
  private reloadPrefs(): void {
    this.engineId = settingsStore.getEngineId();
    this.fromLang = settingsStore.getFromLang();
    this.toLang = settingsStore.getToLang();
    this.ttsEngineId = settingsStore.getTtsEngineId();
    this.ocrEngineId = settingsStore.getOcrEngineId();
    this.ocrSaveGallery = settingsStore.getOcrSaveToGallery();
    this.lastBackupAt = BackupService.lastBackupAt();
    this.refreshPluginEngines();
    const cm = settingsStore.getColorModePref();
    if (cm !== this.colorModePref) {
      // 值变化才应用：setColorMode 会触发全树按新配色重建（切页签时的怪动画根因）
      this.applyColorMode(cm);
    } else {
      this.colorModePref = cm;
    }
  }

  private backupTimeText(): string {
    if (this.lastBackupAt === 0) {
      return '从未备份';
    }
    const d = new Date(this.lastBackupAt);
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  build() {
    Column() {
      Scroll() {
      Column({ space: 14 }) {
        // 主页大标题栏：透明背景与页面同色（主页不放返回键）
        Column({ space: 2 }) {
          Text('我的')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Text('鸿译 TransHarmony')
            .fontSize(12)
            .fontColor($r('app.color.font_tertiary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: 4, bottom: 10 })

        // ── 翻译服务入口 ──
        Column() {
          this.sectionLabel('服务')

          Column() {
            Row({ space: 12 }) {
              Text('译')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .width(42)
                .height(42)
                .textAlign(TextAlign.Center)
                .borderRadius(16)
                .linearGradient({ angle: 135, colors: [['#0A59F7', 0.0], ['#0A9BFF', 1.0]] })
              Column({ space: 2 }) {
                Text('翻译服务')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_primary'))
                Text('免费开箱即翻 · 官方 API 与 AI 服务商')
                  .fontSize(12)
                  .lineHeight(17)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_fourth')])
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openServices();
            })
          }
          .width('100%')
          .padding({ left: 14, right: 14 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 0.8, color: $r('app.color.divider') })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 偏好设置 ──
        Column() {
          this.sectionLabel('偏好设置')

          Column() {
            Row() {
              Text('默认引擎')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Select(this.engineOptions().map((it: EngineOption): SelectOption => ({ value: it.label })))
                .selected(this.engineOptionIndex())
                .value(this.engineLabel(this.engineId))
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  const opts = this.engineOptions();
                  if (index >= 0 && index < opts.length) {
                    this.pickDefaultEngine(opts[index].id);
                  }
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('默认语言对')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Select(this.fromItems().map((it: LanguageItem): SelectOption => ({ value: it.label })))
                .selected(this.indexOfFrom())
                .value(this.langLabelOf(this.fromLang))
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  const list = this.fromItems();
                  if (index >= 0 && index < list.length) {
                    this.setLang(list[index].code, this.toLang);
                  }
                })
              SymbolGlyph($r('sys.symbol.arrow_right'))
                .fontSize(12)
                .fontColor([$r('app.color.font_tertiary')])
                .margin({ left: 4, right: 4 })
              Select(LANGUAGE_LIST.map((it: LanguageItem): SelectOption => ({ value: it.label })))
                .selected(this.indexOfTo())
                .value(this.langLabelOf(this.toLang))
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  if (index >= 0 && index < LANGUAGE_LIST.length) {
                    this.setLang(this.fromLang, LANGUAGE_LIST[index].code);
                  }
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('语音服务TTS')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Select(this.serviceOptions(this.ttsPlugins))
                .selected(this.serviceSelectedIndex(this.ttsEngineId, this.ttsPlugins))
                .value(this.serviceSelectedLabel(this.ttsEngineId, this.ttsPlugins))
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  if (index <= 0) {
                    this.pickTtsEngine('system');
                  } else if (index - 1 < this.ttsPlugins.length) {
                    this.pickTtsEngine(this.ttsPlugins[index - 1].engineId);
                  }
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('文字识别服务OCR')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Select(this.serviceOptions(this.ocrPlugins))
                .selected(this.serviceSelectedIndex(this.ocrEngineId, this.ocrPlugins))
                .value(this.serviceSelectedLabel(this.ocrEngineId, this.ocrPlugins))
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  if (index <= 0) {
                    this.pickOcrEngine('system');
                  } else if (index - 1 < this.ocrPlugins.length) {
                    this.pickOcrEngine(this.ocrPlugins[index - 1].engineId);
                  }
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('深色模式')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Select([{ value: '跟随系统' }, { value: '浅色' }, { value: '深色' }])
                .selected(this.colorModeIndex())
                .value(this.colorModeLabel())
                .font({ size: 12.5 })
                .fontColor($r('app.color.font_secondary'))
                .selectedOptionFont({ size: 13.5 })
                .optionFont({ size: 13.5 })
                .onSelect((index: number): void => {
                  this.applyColorMode(['system', 'light', 'dark'][index]);
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Column({ space: 2 }) {
                Text('拍照后提供保存到相册')
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                Text('开启后拍照翻译完成会出现「保存图片」按钮')
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.ocrSaveGallery })
                .width(40)
                .height(24)
                .selectedColor($r('app.color.brand'))
                .onChange((on: boolean) => {
                  this.ocrSaveGallery = on;
                  settingsStore.setOcrSaveToGallery(on);
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 0.8, color: $r('app.color.divider') })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 数据（备份与恢复）──
        Column() {
          this.sectionLabel('数据')

          Column() {
            Row() {
              Column({ space: 2 }) {
                Text('立即备份')
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                Text('历史、服务商、语音/识别服务与插件（密码可选）导出到 Download/鸿译 目录')
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.backupBusy) {
                LoadingProgress().width(20).height(20).color($r('app.color.brand'))
              } else {
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('app.color.font_fourth')])
              }
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .onClick(() => {
              this.openBackupDialog();
            })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Column({ space: 2 }) {
                Text('从文件恢复')
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                Text('选择 .htrans 备份文件，历史可合并或覆盖')
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_fourth')])
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .onClick(() => {
              this.openRestore();
            })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('上次备份')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Text(this.backupTimeText())
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 0.8, color: $r('app.color.divider') })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ── 关于 ──
        Column() {
          this.sectionLabel('关于')

          Column() {
            Row() {
              Text('隐私政策')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_fourth')])
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .onClick(() => {
              this.pathStack.pushPath({ name: 'PrivacyPage' });
            })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('用户反馈交流')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_fourth')])
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .onClick(() => {
              this.pathStack.pushPath({ name: 'FeedbackPage' });
            })

            Divider().color($r('app.color.divider')).strokeWidth(0.8)

            Row() {
              Text('关于鸿译')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Text('版本 ' + APP_VERSION)
                .fontSize(11)
                .fontColor($r('app.color.font_tertiary'))
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14)
                .fontColor([$r('app.color.font_fourth')])
                .margin({ left: 6 })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13 })
            .onClick(() => {
              this.pathStack.pushPath({ name: 'AboutPage' });
            })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_bg'))
          .border({ width: 0.8, color: $r('app.color.divider') })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 底部滚动余量（避让页签胶囊与导航条）
        Row()
          .height(130 + this.navBarH + 24)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      // 平板等宽屏：表单卡片最大 720vp 居中（Scroll align Top 已含横向居中）
      .constraintSize({ maxWidth: this.winW >= 600 ? 720 : 100000 })
    }
      .width('100%')
      .layoutWeight(1)
      // fadingEdge 生效时组件上不设 background（官方注意事项），底色由外层提供
      .scrollable(ScrollDirection.Vertical)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      // 官方边缘渐隐（API 14+）：上滑内容在状态栏下方 alpha 渐隐溶入，无布局占用
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(40) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  // ---- 子构建器 ----

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

  // ---- 辅助 ----

  private engineOptions(): EngineOption[] {
    // 免费通道 + 已启用且已配置的服务实例（与引擎选择面板一致）
    const list: EngineOption[] = [];
    for (const a of EngineRegistry.all()) {
      if (!a.needsConfig) {
        list.push({ id: a.id, label: a.label });
      }
    }
    const usable = new Set(TranslateUseCase.usableEngineIds());
    for (const a of EngineRegistry.all()) {
      if (a.needsConfig && usable.has(a.id)) {
        list.push({ id: a.id, label: a.isAI ? a.label + '（AI）' : a.label });
      }
    }
    return list;
  }

  private engineOptionIndex(): number {
    const idx = this.engineOptions().findIndex((it: EngineOption): boolean => it.id === this.engineId);
    return idx >= 0 ? idx : 0;
  }
}
