/**
 * 翻译页：语言选择条（官方 Select 下拉）+ 引擎状态按钮行（可拖拽排序/关闭/添加）
 * + 输入即译 + 常驻译文卡。
 * 三种模式：单引擎与聚合（并发所有已配置引擎，多结果并列）。
 * AI 引擎支持风格指令 chips（官方 ChipGroup）。
 * 拍照按钮弹菜单二选一（拍照/从相册选图），取图后进入图片翻译二级页
 * （ImageTranslatePage：NavDestination + bindSheet 三档拖拽面板）。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import {
  ChipGroup,
  ChipGroupItemOptions,
  LengthMetrics
} from '@kit.ArkUI';
import {
  AUTO_DETECT,
  AggregateItem,
  LangCode,
  STYLE_OPTIONS,
  StyleOption,
  TranslationResult,
  TranslateStyle
} from '../models/TranslationTypes';
import { EngineRegistry } from '../services/EngineRegistry';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { settingsStore } from '../services/SettingsStore';
import { OFFLINE_ENGINE_ID } from '../services/OfflineTranslator';
import { SpeechService } from '../services/SpeechService';
import { AGGREGATE_ID, EngineSelector, PILL_VERSION_KEY } from '../components/EngineSelector';
import { LangSelector } from '../components/LangSelector';
import { AddProviderPanel } from '../components/AddProviderPanel';
import { ImageTransParam } from './ImageTranslatePage';
import { captureFromCamera, pickFromGallery } from '../utils/ImagePickerUtil';


@Component
export struct TranslatePageContent {
  /** 当前 tab 索引（Index 常驻挂载三页，切回本页 tab 时刷新引擎行） */
  @Link @Watch('onTabChange') currentIndex: number;
  /** 路由栈（Index Navigation 提供），添加服务商时可跳转配置页 */
  @Consume('navPathStack') pathStack: NavPathStack;
  @State fromLang: LangCode = AUTO_DETECT;
  @State toLang: LangCode = 'en';
  /** 'aggregate' 或具体引擎 id（'edge' | 服务实例 id） */
  @State engineId: string = 'edge';
  @State inputText: string = '';
  @State resultText: string = '';
  @State resultMeta: string = '';
  @State detectedFrom: LangCode = '';
  @State loading: boolean = false;
  @State errMsg: string = '';
  @State style: TranslateStyle = 'polished';
  @State aggItems: AggregateItem[] = [];
  @State adoptedEngineId: string = '';
  /** 添加服务商面板显示状态 */
  @State addPanelShow: boolean = false;
  /** 输入朗读状态：'' | 'playing' | 'paused'；译文朗读同 */
  @State speakInputState: string = '';
  @State speakResultState: string = '';
  /** 语音输入暂停态：true 时按钮显示「继续」，点击开新会话接着识别 */
  @State asrPaused: boolean = false;
  @State listening: boolean = false;
  @State ocrRunning: boolean = false;
  /** 用户是否明确选择过目标语言（置位后「自动检测」的智能默认不再覆盖目标语言） */
  private toLangTouched: boolean = false;
  /** 沉浸式导航条避让高度（vp） */
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 引擎行版本号：面板开关内置通道等变更后自愈当前选中引擎 */
  @StorageProp('ux_pill_version') @Watch('onPillsChanged') pillVersion: number = 0;
  /** 沉浸式状态栏避让高度（vp）：页内自行避让，保证蒙层边界与避让区重叠 */
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  /** 窗口宽度（vp）：≥600 判定宽屏（平板/横屏/自由多窗），翻译页切双列 */
  @StorageProp('ux_winW') winW: number = 0;
  private runSeq: number = 0;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 引擎行跨页刷新：任何页 bump 该版本号后引擎 chip 行重算 */
  private bumpPill(): void {
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  aboutToAppear(): void {
    // 优先读 Preferences（EntryAbility 启动后已写入 AppStorage，此处兜底直读）
    const savedEngine = settingsStore.getEngineId();
    if (savedEngine !== undefined && savedEngine.length > 0) {
      this.engineId = savedEngine;
    }
    const savedFrom = settingsStore.getFromLang();
    if (savedFrom !== undefined && savedFrom.length > 0) {
      this.fromLang = savedFrom;
    }
    const savedTo = settingsStore.getToLang();
    if (savedTo !== undefined && savedTo.length > 0) {
      this.toLang = savedTo;
    }
    this.ensureEngineUsable();
  }

  /** 自定义弹窗控制器随组件销毁置空（官方建议写法） */
  aboutToDisappear(): void {
    this.imgSourceDialog = null;
  }

  /** 切回翻译页 tab 时刷新引擎行（服务可能增删/排序/开关） */
  private onTabChange(): void {
    if (this.currentIndex === 0) {
      TranslateUseCase.refreshServices();
      this.bumpPill();
      this.ensureEngineUsable();
    }
  }

  /** 引擎行变更（添加面板开关内置通道/服务开关）后，校正当前选中引擎 */
  private onPillsChanged(): void {
    this.ensureEngineUsable();
  }

  /** 当前引擎若已不可用（被删/停用），回退到第一个可用引擎（聚合模式不处理） */
  private ensureEngineUsable(): void {
    if (this.engineId === AGGREGATE_ID) {
      return;
    }
    const ids = TranslateUseCase.usableEngineIds();
    if (!ids.includes(this.engineId)) {
      this.engineId = ids.length > 0 ? ids[0] : 'edge';
      settingsStore.setEngineId(this.engineId);
      AppStorage.setOrCreate('pref_engine_id', this.engineId);
    }
  }

  /** 拖拽排序落位：chip 行顺序已由组件写入引擎行顺序存储；
   *  两个用户服务之间排序时此处同步服务列表（聚合返回）顺序，其余情况自动忽略 */
  private async reorderService(fromId: string, toId: string): Promise<void> {
    await settingsStore.reorderService(fromId, toId);
    TranslateUseCase.refreshServices();
    this.bumpPill();
  }

  /** 关闭（停用）：内置免费通道走删除开关存储，用户服务走服务列表开关；
   *  两者都从引擎行消失，可在「添加服务商」面板恢复 */
  private async disableService(id: string): Promise<void> {
    const adapter = EngineRegistry.byId(id);
    if (id === OFFLINE_ENGINE_ID) {
      // 离线翻译：× = 关总开关，可在「离线翻译」管理页或添加面板重新开启
      await settingsStore.setOfflineEnabled(false);
      TranslateUseCase.refreshServices();
      this.bumpPill();
      this.ensureEngineUsable();
      this.toast('已停用 ' + (adapter !== undefined ? adapter.label : id) + '，可在「离线翻译」页重新启用');
      return;
    }
    if (EngineRegistry.isBuiltin(id)) {
      // 引擎行 × = 停用：保留在「翻译服务」管理页（已添加），仅从引擎行/聚合隐藏
      await settingsStore.setBuiltinEnabled(
        settingsStore.getBuiltinEnabled().filter((e: string): boolean => e !== id));
      TranslateUseCase.refreshServices();
      this.bumpPill();
      this.ensureEngineUsable();
      this.toast('已停用 ' + (adapter !== undefined ? adapter.label : id) + '，可在「翻译服务」管理页重新启用');
      return;
    }
    await settingsStore.setServiceEnabled(id, false);
    TranslateUseCase.refreshServices();
    this.bumpPill();
    this.ensureEngineUsable();
    this.toast('已停用 ' + (adapter !== undefined ? adapter.label : id) + '，可在「添加」面板重新启用');
  }

  private isAggregateMode(): boolean {
    return this.engineId === AGGREGATE_ID;
  }

  /** AI 引擎（服务实例 defId 以 'ai-' 开头） */
  private isAISelected(): boolean {
    const adapter = EngineRegistry.byId(this.engineId);
    return adapter !== undefined && adapter.isAI;
  }

  /** 宽屏判定（官方断点 ≥600vp：md 双折叠展开 / lg 平板 / xl 三折叠全展开） */
  private isWide(): boolean {
    return this.winW >= 600;
  }

  /** md 档（600-840）：双折叠展开态/阔折叠展开态 */
  private isMd(): boolean {
    return this.winW >= 600 && this.winW < 840;
  }

  /** lg 档及以上（≥840）：平板/三折叠展开 */
  private isLg(): boolean {
    return this.winW >= 840;
  }

  /** 页面内容限宽（vp）：md 720（双折叠展开）/ lg 960（平板）/ xl 1040（超宽三折叠），sm 不限 */
  private pageMax(): number {
    if (this.winW >= 1440) {
      return 1040;
    }
    if (this.isLg()) {
      return 960;
    }
    return this.isMd() ? 720 : 100000;
  }

  // ---- 触发 ----

  private onInputChanged(value: string): void {
    this.inputText = value;
    // 智能语言对实时反映在目标语言胶囊上（翻译本身由按钮触发）
    this.smartTarget();
    if (value.trim().length === 0) {
      this.resultText = '';
      this.errMsg = '';
      this.aggItems = [];
      this.adoptedEngineId = '';
    }
  }

  private runTranslate(): void {
    // 内置通道默认关闭：一个可用引擎都没有时给引导提示，而不是静默失败
    if (!this.isAggregateMode()) {
      const ids = TranslateUseCase.usableEngineIds();
      if (ids.length === 0) {
        this.toast('还没有可用的翻译服务，请在「添加服务商」面板开启内置免费通道或添加服务商');
        return;
      }
      if (!ids.includes(this.engineId)) {
        this.ensureEngineUsable();
      }
    }
    this.smartTarget();
    hilog.info(0x0001, 'TranslatePage', 'runTranslate engineId=%{public}s isAgg=%{public}s AGG=%{public}s',
      this.engineId, String(this.isAggregateMode()), AGGREGATE_ID);
    if (this.isAggregateMode()) {
      this.runAggregate();
    } else {
      this.runSingle();
    }
  }

  /** 是否包含中日韩汉字 */
  private hasCJK(s: string): boolean {
    return /[\u4e00-\u9fff]/.test(s);
  }

  /**
   * 智能语言对（仅「自动检测源语言 + 用户未手动选过目标语言」时生效）：
   * 输入含中文 → 默认译英语；输入非中文 → 默认译中文。
   * 用户一旦明确选定目标语言（pickTo/交换），此处永不再覆盖——修复目标语言被强制改英语的 bug。
   */
  private smartTarget(): void {
    if (this.fromLang !== AUTO_DETECT || this.toLangTouched || this.inputText.trim().length === 0) {
      return;
    }
    const want: LangCode = this.hasCJK(this.inputText) ? 'en' : 'zh';
    if (this.toLang !== want) {
      this.toLang = want;
    }
  }

  private async runSingle(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0 || this.loading) {
      return;
    }
    this.loading = true;
    this.errMsg = '';
    this.resultText = '';
    this.resultMeta = '';
    const seq = ++this.runSeq;
    try {
      const result = await TranslateUseCase.translate(text, this.fromLang, this.toLang,
        this.engineId, this.isAISelected() ? this.style : 'plain', undefined,
        (fullText: string): void => {
          // 流式增量（AI / 支持流式的插件）：实时刷新结果区；过期轮次丢弃
          if (seq !== this.runSeq) {
            return;
          }
          this.resultText = fullText;
        });
      if (seq !== this.runSeq) {
        return;
      }
      this.resultText = result.text;
      this.detectedFrom = result.detectedFrom ?? '';
      const pair = TranslateUseCase.describePair(result.detectedFrom ?? this.fromLang, this.toLang);
      const engine = EngineRegistry.byId(this.engineId);
      this.resultMeta = (engine !== undefined ? engine.label + ' · ' : '') + pair;
    } catch (e) {
      if (seq !== this.runSeq) {
        return;
      }
      this.errMsg = e instanceof Error ? (this.isAISelected() ? 'AI 翻译失败：' : '翻译失败：') + e.message
        : '翻译失败，请检查网络后重试';
    } finally {
      if (seq === this.runSeq) {
        this.loading = false;
      }
    }
  }

  private runAggregate(): void {
    const text = this.inputText.trim();
    if (text.length === 0) {
      return;
    }
    const ids = TranslateUseCase.configuredEngineIds();
    hilog.info(0x0001, 'TranslatePage', 'runAggregate ids=%{public}s', JSON.stringify(ids));
    if (ids.length === 0) {
      this.toast('还没有可用的翻译服务，请到「我的 → 翻译服务」添加');
      return;
    }
    this.loading = true;
    this.errMsg = '';
    this.resultText = '';
    this.adoptedEngineId = '';
    const seq = ++this.runSeq;
    const start = Date.now();
    TranslateUseCase.aggregate(text, this.fromLang, this.toLang, ids, this.style,
      (items: AggregateItem[]): void => {
        if (seq !== this.runSeq) {
          return;
        }
        hilog.info(0x0001, 'TranslatePage', 'aggUpdate n=%{public}d', items.length);
        this.aggItems = items;
        const allDone = items.every((it: AggregateItem): boolean => it.status !== 'loading');
        if (allDone) {
          this.loading = false;
          this.resultMeta = items.length + ' 个引擎已返回 · 耗时 ' + (Date.now() - start) + 'ms';
        }
      }).catch((e: Object): void => {
        // 敏感词拦截等启动期失败：聚合未产出任何条目，走错误栏统一展示
        if (seq !== this.runSeq) {
          return;
        }
        this.loading = false;
        this.errMsg = e instanceof Error ? e.message : '翻译失败，请检查网络后重试';
      });
  }

  /** 聚合模式：采用某引擎结果（写入历史） */
  private async adopt(item: AggregateItem): Promise<void> {
    if (item.status !== 'done' || this.adoptedEngineId === item.engineId) {
      return;
    }
    this.adoptedEngineId = item.engineId;
    const result: TranslationResult = { text: item.text, providerId: item.engineId };
    await TranslateUseCase.saveAdopted(this.inputText.trim(), result, item.engineId,
      this.fromLang, this.toLang);
    this.toast('已采用 ' + item.label + ' 译文并存入历史');
  }

  // ---- 操作 ----

  private async copyText(text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('已复制');
  }

  /** Core Speech Kit TTS 仅支持中英（官方文档），其余语种显示「不支持」 */
  private ttsSupported(code: string): boolean {
    return SpeechService.isLangSupported(code);
  }

  /** 输入朗读语言：手动源语言优先；自动检测时用检测结果，尚未检测过则视为中文 */
  private inputLangTag(): string {
    if (this.fromLang !== AUTO_DETECT) {
      return this.fromLang;
    }
    if (this.detectedFrom.length > 0) {
      return this.detectedFrom;
    }
    return 'zh';
  }

  private speakInputLabel(): string {
    if (this.speakInputState === 'playing') {
      return '暂停';
    }
    if (this.speakInputState === 'paused') {
      return '继续';
    }
    return this.ttsSupported(this.inputLangTag()) ? '朗读' : '不支持';
  }

  /** 输入框朗读：只读输入内容，按输入语言选 TTS 引擎；播放中点=暂停，暂停中点=继续 */
  private async speakInput(): Promise<void> {
    if (this.speakInputState === 'playing') {
      this.speakInputState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.speakInputState === 'paused') {
      this.speakInputState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    const text = this.inputText.trim();
    if (text.length === 0) {
      this.toast('没有可朗读的内容');
      return;
    }
    const lang = this.inputLangTag();
    if (!this.ttsSupported(lang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    // 单 TTS 通道：开始新的朗读前复位另一路的按钮状态
    this.speakResultState = '';
    this.speakInputState = 'playing';
    try {
      await SpeechService.speak(text, lang, 'input', (): void => {
        // 播完/停止/出错：复位（注意不要覆盖暂停态以外的 UI 状态）
        this.speakInputState = '';
      });
    } catch (e) {
      this.speakInputState = '';
      this.toast('朗读启动失败：' + this.errText(e));
    }
  }

  /** 译文朗读：只读译文，按目标语言选引擎；播放中点=暂停，暂停中点=继续 */
  private async speakResult(): Promise<void> {
    if (this.speakResultState === 'playing') {
      this.speakResultState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.speakResultState === 'paused') {
      this.speakResultState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    if (this.resultText.length === 0) {
      return;
    }
    if (!this.ttsSupported(this.toLang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    this.speakInputState = '';
    this.speakResultState = 'playing';
    try {
      await SpeechService.speak(this.resultText, this.toLang, 'result', (): void => {
        this.speakResultState = '';
      });
    } catch (e) {
      this.speakResultState = '';
      this.toast('朗读启动失败：' + this.errText(e));
    }
  }

  /** 切换语言/引擎/新翻译等场景：终止朗读与识别（自动复位按钮状态） */
  private stopAllSpeech(): void {
    if (this.speakInputState !== '' || this.speakResultState !== '') {
      SpeechService.stopSpeak();
      this.speakInputState = '';
      this.speakResultState = '';
    }
    if (this.listening) {
      this.listening = false;
      SpeechService.cancelAsr();
    }
  }

  /** 统一提取异常信息：BusinessError 不是 Error 实例（err.message 在其 code 属性上），
   *  直接 String() 会得到 [object Object]，这里分别取 code+message */
  private errText(e: Object): string {
    const be = e as BusinessError;
    if (be !== null && be !== undefined && be.code !== undefined) {
      return be.code + ' ' + (be.message ?? '');
    }
    if (e instanceof Error) {
      const m = e.message;
      return m.length > 0 ? m : String(e);
    }
    return String(e);
  }

  /** 语音输入：麦克风权限 → ASR 识别（Core Speech Kit，引擎内部录音）。
   *  收音中点击 = 暂停（finish 当前会话，文本保留）；再点 = 继续开新会话接着识别。
   *  识别出的文本达到 2 秒无新结果时自动翻译——此处沿用「暂停时翻译」策略：
   *  用户点暂停视为一句话说完，暂停即触发翻译。 */
  private async toggleListen(): Promise<void> {
    if (this.listening) {
      // 暂停：finish 会话（onComplete 回调里自动翻译已识别文本），按钮进「继续」态
      this.listening = false;
      this.asrPaused = true;
      SpeechService.pauseAsr();
      return;
    }
    if (this.speakInputState !== '' || this.speakResultState !== '') {
      SpeechService.stopSpeak();
      this.speakInputState = '';
      this.speakResultState = '';
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    const permissions: Array<Permissions> = ['ohos.permission.MICROPHONE'];
    const grant = await atManager.requestPermissionsFromUser(ctx, permissions);
    let granted = false;
    for (const r of grant.authResults) {
      if (r === 0) {
        granted = true;
      }
    }
    if (!granted) {
      this.toast('需要麦克风权限才能语音输入');
      return;
    }
    this.listening = true;
    this.asrPaused = false;
    this.toast('请说话，再次点击「暂停」结束');
    try {
      await SpeechService.startAsr((text: string): void => {
        // 中间结果实时回填输入框
        this.inputText = text;
        this.smartTarget();
      }, (errMsg: string): void => {
        this.listening = false;
        if (errMsg.length > 0) {
          this.toast('语音识别失败：' + errMsg);
        } else if (this.inputText.trim().length > 0) {
          // 会话结束（含用户点暂停）自动翻译
          this.runTranslate();
        }
      });
    } catch (e) {
      this.listening = false;
      this.toast('语音识别启动失败：' + this.errText(e));
    }
  }

  /** 图片来源选择弹窗（拍照/相册双图标卡片），打开后点卡片进入图片翻译页 */
  private imgSourceDialog: CustomDialogController | null = new CustomDialogController({
    builder: ImageSourceDialog({
      onPick: (source: string): void => {
        this.enterImageTrans(source);
      }
    }),
    autoCancel: true,
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -12 }
  });

  /** 拍照按钮：弹出来源选择（拍照/相册），取图后进入图片翻译二级页 */
  private openImageTranslate(): void {
    if (this.ocrRunning) {
      return;
    }
    if (this.imgSourceDialog !== null) {
      this.imgSourceDialog.open();
    }
  }

  /** 拍照/选图后推入图片翻译页：PixelMap 所有权移交页面，页面销毁时释放 */
  private async enterImageTrans(source: string): Promise<void> {
    if (this.ocrRunning) {
      return;
    }
    this.ocrRunning = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pm = source === 'camera' ? await captureFromCamera(ctx) : await pickFromGallery(ctx);
      if (pm === null) {
        return; // 用户取消
      }
      const param: ImageTransParam = {
        pm: pm,
        canSave: source === 'camera' && settingsStore.getOcrSaveToGallery(),
        toLang: this.toLang,
        engineId: this.engineId !== AGGREGATE_ID ? this.engineId : this.lastSingleEngine(),
        style: this.style
      };
      this.pathStack.pushPath({ name: 'ImageTranslatePage', param: param });
    } catch (e) {
      this.toast((source === 'camera' ? '拍照失败：' : '选择图片失败：') + this.errText(e));
    } finally {
      this.ocrRunning = false;
    }
  }

  /** 最近使用过的单引擎（主页聚合模式下进图片翻译页时的兜底） */
  private lastSingleEngine(): string {
    const saved = settingsStore.getEngineId();
    if (saved !== undefined && saved.length > 0 && saved !== AGGREGATE_ID) {
      return saved;
    }
    return 'edge';
  }


  private swap(): void {
    if (this.fromLang === AUTO_DETECT) {
      this.toast('自动检测状态下不能交换，请先选择源语言');
      return;
    }
    const tmp = this.fromLang;
    this.fromLang = this.toLang;
    this.toLang = tmp;
    this.detectedFrom = '';
    this.toLangTouched = true;
    AppStorage.setOrCreate('pref_from_lang', this.fromLang);
    AppStorage.setOrCreate('pref_to_lang', this.toLang);
  }

  /** 选择源语言（与目标语言相同时自动互换，避免两侧同语言） */
  private pickFrom(code: LangCode): void {
    this.stopAllSpeech();
    if (this.toLang === code) {
      this.toLang = this.fromLang !== AUTO_DETECT ? this.fromLang : 'zh';
      AppStorage.setOrCreate('pref_to_lang', this.toLang);
    }
    this.fromLang = code;
    this.detectedFrom = '';
    AppStorage.setOrCreate('pref_from_lang', code);
  }

  /** 选择目标语言：明确选择后「自动检测」的智能默认不再覆盖 */
  private pickTo(code: LangCode): void {
    this.stopAllSpeech();
    if (this.fromLang === code) {
      this.fromLang = this.toLang;
      AppStorage.setOrCreate('pref_from_lang', this.fromLang);
    }
    this.toLang = code;
    this.toLangTouched = true;
    AppStorage.setOrCreate('pref_to_lang', code);
  }

  private pickEngine(id: string): void {
    this.stopAllSpeech();
    if (id === AGGREGATE_ID) {
      this.engineId = AGGREGATE_ID;
    } else {
      this.engineId = id;
      settingsStore.setEngineId(id);
    }
    AppStorage.setOrCreate('pref_engine_id', this.engineId);
  }

  private engineRowLabel(id: string): string {
    if (id === AGGREGATE_ID) {
      return '聚合翻译';
    }
    const hit = EngineRegistry.byId(id);
    return hit !== undefined ? hit.label : id;
  }

  /** 引擎显示名（Select 选项与结果 meta 用） */
  private engineLabel(id: string): string {
    const hit = EngineRegistry.byId(id);
    return hit !== undefined ? hit.label : id;
  }

  // ---- 官方组件数据源 ----

  /** AI 风格指令 chips（官方 ChipGroup 数据源） */
  private styleChipItems(): ChipGroupItemOptions[] {
    const items: ChipGroupItemOptions[] = [];
    for (const opt of STYLE_OPTIONS) {
      items.push({ label: { text: opt.label } });
    }
    return items;
  }

  private styleIndex(): number {
    const idx = STYLE_OPTIONS.findIndex((opt: StyleOption): boolean => opt.value === this.style);
    return idx >= 0 ? idx : 0;
  }


  // ---- UI ----

  build() {
    Stack() {
      Column() {
        this.header()
        Scroll() {
        Column({ space: 11 }) {
          if (this.isWide()) {
            // 宽屏工作台：语言条限宽 640 与卡片左缘对齐 → 引擎 chips 通栏 →
            // 下方输入卡与译文卡左右并排（Flex 等高拉伸，左卡跟随右列内容高度）；
            // 内容不足一屏由 Scroll 垂直居中
            this.langCard()
            this.engineRow()
            this.styleChipsRow()
            Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
              Column() {
                this.inputCard()
              }
              .flexGrow(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ right: 16 })

              Column() {
                this.resultArea()
              }
              .flexGrow(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
          } else {
            this.langCard()
            this.engineRow()
            this.styleChipsRow()
            this.inputCard()
            this.resultArea()
          }
        }
        // 底部避让需 ≥ Index 渐隐层高度（84 + navBarH）；平板等宽屏内容限宽居中
        .padding({ left: 16, right: 16, top: this.isWide() ? 0 : 4, bottom: 96 + this.navBarH })
        .width('100%')
        .constraintSize({ maxWidth: this.pageMax() })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        // 宽屏且内容不足一屏时：工作台整体在视口垂直居中；窄屏/内容超高时顶对齐可滚动
        .align(this.isWide() ? Alignment.Center : Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        // 官方边缘渐隐（API 14+）：上滑内容在标题区下方 alpha 渐隐溶入，无布局占用
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(40) })
      }
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    // 添加服务商改为 bindSheet 半模态：蒙层是页面级 overlay，盖住底部页签；
    // 返回键/蒙层点击由 bindSheet 默认行为关闭，不再退出应用。
    // $$ 双向绑定必须保留：蒙层/下拉/返回关闭时系统回写 addPanelShow=false，
    // 单向绑定下状态残留 true，下次点「+添加」赋值无变化、面板弹不出来
    .bindSheet($$this.addPanelShow, this.addSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      showClose: false,
      // 官方推荐（折叠屏最佳实践）：<600vp 底部弹出，md/lg 大屏自动适配居中跟手弹窗
      preferType: SheetType.POPUP,
      backgroundColor: $r('app.color.card_bg')
    })
  }

  /** 添加服务商半模态内容（限宽居中，适配平板全宽 sheet） */
  @Builder
  addSheetBuilder() {
    Column() {
      AddProviderPanel({
        onClose: (): void => {
          this.addPanelShow = false;
        },
        onOpenConfig: (serviceId: string): void => {
          const param: Record<string, string> = { 'serviceId': serviceId };
          this.pathStack.pushPath({ name: 'ServiceConfigPage', param: param });
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 主页大标题栏：透明背景与页面同色；重译入口在结果卡，设置走底部页签。
   *  宽屏与内容区同限宽居中，标题不再贴屏幕左缘 */
  @Builder
  header() {
    Column({ space: 1 }) {
      Text('翻译')
        .fontSize(this.isWide() ? 28 : 24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
      Text('鸿译 TransHarmony')
        .fontSize(12)
        .fontColor($r('app.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .constraintSize({ maxWidth: this.pageMax() })
    .padding({ left: 20, right: 20, top: this.statusBarH + (this.isWide() ? 12 : 4), bottom: 10 })
  }

  // ---- 单引擎结果卡（常驻：空态 / 加载中 / 已出译文） ----
  // 定义在 resultArea() 之后（文件尾部）

  /** 输入框朗读按钮：播放中=「暂停」/ 暂停中=「继续」/ 语言不支持=置灰「不支持」 */
  @Builder
  speakButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.speakInputState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(16)
        .fontColor(this.speakInputState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')] : [$r('app.color.font_secondary')])
      Text(this.speakInputLabel())
        .fontSize(12)
        .fontColor(this.speakInputState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.inputLangTag())
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(44)
    .borderRadius(12)
    .backgroundColor(this.speakInputState !== '' ? $r('app.color.brand') : $r('app.color.bg_container'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakInput();
    })
  }

  /** 译文朗读按钮：仅作用于译文；播放中=「暂停」/ 暂停中=「继续」/ 不支持=置灰 */
  @Builder
  resultSpeakButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.speakResultState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(15)
        .fontColor(this.speakResultState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')]
          : (this.ttsSupported(this.toLang)
            ? [$r('app.color.font_secondary')] : [$r('app.color.font_fourth')]))
      Text(this.speakResultState === 'playing' ? '暂停'
        : (this.speakResultState === 'paused' ? '继续'
          : (this.ttsSupported(this.toLang) ? '朗读' : '不支持')))
        .fontSize(12)
        .fontColor(this.speakResultState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.toLang)
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor(this.speakResultState !== '' ? $r('app.color.brand') : $r('app.color.bg_container'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakResult();
    })
  }

  /** 语音按钮：收音中高亮「暂停」；暂停后高亮「继续」（点击接着识别）；空闲「语音」 */
  @Builder
  micButton() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.mic_fill'))
        .fontSize(16)
        .fontColor(this.listening || this.asrPaused
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')] : [$r('app.color.font_secondary')])
      Text(this.listening ? '暂停' : (this.asrPaused ? '继续' : '语音'))
        .fontSize(12)
        .fontColor(this.listening || this.asrPaused
          ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('app.color.font_secondary'))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(44)
    .borderRadius(12)
    .backgroundColor(this.listening || this.asrPaused
      ? $r('app.color.brand') : $r('app.color.bg_container'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.toggleListen();
    })
  }

  /** 拍照按钮：高亮=识别进行中 */
  @Builder
  cameraButton() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.camera'))
        .fontSize(16)
        .fontColor(this.ocrRunning
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')] : [$r('app.color.font_secondary')])
      Text(this.ocrRunning ? '识别中' : '拍照')
        .fontSize(12)
        .fontColor(this.ocrRunning
          ? $r('sys.color.ohos_id_color_text_primary_contrary') : $r('app.color.font_secondary'))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(44)
    .borderRadius(12)
    .backgroundColor(this.ocrRunning ? $r('app.color.brand') : $r('app.color.bg_container'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.openImageTranslate();
    })
  }

  /** 译文操作按钮：与输入框工具按钮同款（等宽、40 高、圆角块） */
  @Builder
  resultAction(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 6 }) {
      SymbolGlyph(icon)
        .fontSize(15)
        .fontColor([$r('app.color.font_secondary')])
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor($r('app.color.bg_container'))
    .onClick(() => {
      onTap();
    })
  }

  /** 语言条卡片：官方 Select 下拉选择源/目标语言 + 交换按钮。
   *  宽屏限宽 480vp 水平居中置顶（层级的视觉锚点）；窄屏通栏 */
  @Builder
  langCard() {
    Column() {
      LangSelector({
        fromLang: this.fromLang,
        toLang: this.toLang,
        detectedFrom: this.detectedFrom,
        onPickFrom: (code: LangCode): void => this.pickFrom(code),
        onPickTo: (code: LangCode): void => this.pickTo(code),
        onSwap: (): void => this.swap()
      })
    }
    .width('100%')
    // 宽屏语言条限宽 640 居中显示（官方平板居中布局）；sm 保持全宽不变
    .constraintSize({ maxWidth: this.isWide() ? 640 : 100000 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
  }

  /** 引擎状态按钮行：点击切换（弹跳动画）、用户服务可拖拽排序/关闭、行尾「＋添加」 */
  @Builder
  engineRow() {
    EngineSelector({
      engineId: this.engineId,
      onPick: (id: string): void => this.pickEngine(id),
      onReorder: (fromId: string, toId: string): void => {
        this.reorderService(fromId, toId);
      },
      onDisable: (id: string): void => {
        this.disableService(id);
      },
      onAdd: (): void => {
        this.addPanelShow = true;
      }
    })
  }

  /** AI 风格指令 chips（官方 ChipGroup，仅 AI 引擎显示） */
  @Builder
  styleChipsRow() {
    if (this.isAISelected() && !this.isAggregateMode()) {
      ChipGroup({
        items: this.styleChipItems(),
        selectedIndexes: [this.styleIndex()],
        onChange: (sel: Array<number>): void => {
          if (sel.length > 0 && sel[0] >= 0 && sel[0] < STYLE_OPTIONS.length) {
            this.style = STYLE_OPTIONS[sel[0]].value;
          }
        }
      })
    }
  }

  /** 输入卡：多行输入 + 朗读/语音/拍照 + 翻译按钮；宽屏填满列高（Flex 等高拉伸） */
  @Builder
  inputCard() {
    Column() {
      if (this.isWide()) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          TextArea({ placeholder: '输入要翻译的文本', text: this.inputText })
            .placeholderFont({ size: 14 })
            .placeholderColor($r('app.color.font_fourth'))
            .fontSize(16)
            .fontColor($r('app.color.font_primary'))
            .backgroundColor(Color.Transparent)
            // 宽屏：填满 Stack（layoutWeight 分配的剩余高度），lg 档给更舒适的初始高度
            .constraintSize({ minHeight: this.isLg() ? 240 : 180 })
            .padding({ left: 0, right: 0, top: 8, bottom: 26 })
            .includeFontPadding(true)
            .width('100%')
            .height('100%')
            .onChange((value: string): void => this.onInputChanged(value))

          Text(this.inputText.length.toString() + '/2000')
            .fontSize(11)
            .fontColor($r('app.color.font_fourth'))
            .margin({ right: 2, bottom: 4 })
        }
        .width('100%')
        .layoutWeight(1)

        // 朗读/语音/拍照：三枚等宽操作按钮（激活时高亮）
        Row({ space: 8 }) {
          this.speakButton()
          this.micButton()
          this.cameraButton()
        }
        .width('100%')
        .margin({ top: 10 })

        // 原生等待态：Button 内嵌 LoadingProgress（官方加载按钮样式）
        Button() {
          Row({ space: 8 }) {
            if (this.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('sys.color.ohos_id_color_text_primary_contrary'))
            }
            Text(this.loading ? '翻译中' : '翻译')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(46)
        .borderRadius(23)
        .backgroundColor($r('app.color.brand'))
        .margin({ top: 10 })
        .enabled(!this.loading && this.inputText.trim().length > 0)
        .onClick(() => {
          this.runTranslate();
        })
      } else {
        Stack({ alignContent: Alignment.BottomEnd }) {
          TextArea({ placeholder: '输入要翻译的文本', text: this.inputText })
            .placeholderFont({ size: 14 })
            .placeholderColor($r('app.color.font_fourth'))
            .fontSize(16)
            .fontColor($r('app.color.font_primary'))
            .backgroundColor(Color.Transparent)
            .constraintSize({ minHeight: 110, maxHeight: 180 })
            .padding({ left: 0, right: 0, top: 8, bottom: 26 })
            .includeFontPadding(true)
            .width('100%')
            .onChange((value: string): void => this.onInputChanged(value))

          Text(this.inputText.length.toString() + '/2000')
            .fontSize(11)
            .fontColor($r('app.color.font_fourth'))
            .margin({ right: 2, bottom: 4 })
        }
        .width('100%')

        // 朗读/语音/拍照：三枚等宽操作按钮（激活时高亮）
        Row({ space: 8 }) {
          this.speakButton()
          this.micButton()
          this.cameraButton()
        }
        .width('100%')
        .margin({ top: 10 })

        // 原生等待态：Button 内嵌 LoadingProgress（官方加载按钮样式）
        Button() {
          Row({ space: 8 }) {
            if (this.loading) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('sys.color.ohos_id_color_text_primary_contrary'))
            }
            Text(this.loading ? '翻译中' : '翻译')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(40)
        .borderRadius(20)
        .backgroundColor($r('app.color.brand'))
        .margin({ top: 10 })
        .enabled(!this.loading && this.inputText.trim().length > 0)
        .onClick(() => {
          this.runTranslate();
        })
      }
    }
    .width('100%')
    // 宽屏双列等高：md 320 / lg 420 最小高（与译文列各分支卡片一致）；
    // 不能用 height('100%')——在 Scroll 里会取视口高度把卡片撑满整屏
    .constraintSize({ minHeight: this.isLg() ? 420 : (this.isMd() ? 320 : 0) })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  /** 译文区：单引擎结果卡或聚合结果 + 错误提示（宽屏为右列） */
  @Builder
  resultArea() {
if (!this.loading && TranslateUseCase.usableEngineIds().length === 0) {
  this.noEngineGuide()
} else if (this.isAggregateMode()) {
if (this.aggItems.length === 0) {
  if (this.loading) {
    // 聚合等待态：与单引擎一致的原生 LoadingProgress
    Row({ space: 10 }) {
      LoadingProgress().width(20).height(20).color($r('app.color.brand'))
      Text('正在并发所有引擎')
        .fontSize(14)
        .fontColor($r('app.color.font_secondary'))
    }
    .width('100%')
    .padding({ top: 26, bottom: 26 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
  } else {
  Column({ space: 6 }) {
    SymbolGlyph($r('sys.symbol.square_fill_grid_2x2'))
      .fontSize(28)
      .fontColor([$r('app.color.font_fourth')])
    Text('聚合模式：点「翻译」并发所有引擎，结果在此逐个显示')
      .fontSize(12)
      .fontColor($r('app.color.font_tertiary'))
      .textAlign(TextAlign.Center)
  }
  .width('100%')
  .padding({ top: 22, bottom: 22 })
  .borderRadius(16)
  .backgroundColor($r('app.color.card_bg'))
  .border({ width: 0.8, color: $r('app.color.divider') })
  .alignItems(HorizontalAlign.Center)
  }
} else {
  Row({ space: 7 }) {
    Row({ space: 4 }) {
      if (this.adoptedEngineId.length > 0) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(11)
          .fontColor([$r('app.color.confirm')])
      }
      Text(this.adoptedEngineId.length > 0
        ? '已采用：' + this.engineRowLabel(this.adoptedEngineId)
        : '点「采用」把该结果存入历史')
        .fontSize(11)
        .fontWeight(this.adoptedEngineId.length > 0 ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.adoptedEngineId.length > 0 ? $r('app.color.confirm') : $r('app.color.font_tertiary'))
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .borderRadius(999)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .alignItems(VerticalAlign.Center)
    Blank()
  }
  .width('100%')

  ForEach(this.aggItems, (item: AggregateItem) => {
    Column() {
      Row({ space: 6 }) {
        if (item.isAI) {
          SymbolGlyph($r('sys.symbol.AI'))
            .fontSize(11)
            .fontColor([$r('app.color.brand')])
        }
        Text(item.label)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(item.isAI ? $r('app.color.brand') : $r('app.color.font_secondary'))
        if (this.adoptedEngineId === item.engineId) {
          Row({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(10)
              .fontColor([$r('app.color.confirm')])
            Text('已采用')
              .fontSize(11)
              .fontColor($r('app.color.confirm'))
          }
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor('#2664BB5C')
          .alignItems(VerticalAlign.Center)
        }
        Blank()
        if (item.status === 'done') {
          Text(item.elapsedMs.toString() + 'ms · ' + (item.isAI ? 'BYOK' : '免费'))
            .fontSize(11)
            .fontColor($r('app.color.font_tertiary'))
          Text('采用')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .border({ width: 1, color: $r('app.color.brand') })
            .borderRadius(999)
            .padding({ left: 9, right: 9, top: 2, bottom: 2 })
            .onClick(() => {
              this.adopt(item);
            })
        } else if (item.status === 'error') {
          Text('失败')
            .fontSize(11)
            .fontColor($r('app.color.warning'))
        } else {
          LoadingProgress().width(14).height(14).color($r('app.color.font_tertiary'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (item.status === 'done' && item.text.length > 0) {
        Text(item.text)
          .fontSize(14)
          .lineHeight(21)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
          .margin({ top: 7 })
          .copyOption(CopyOptions.LocalDevice)
        // AI 生成内容提示（合规）：聚合模式下 AI 引擎的结果卡展示
        if (item.isAI) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.AI'))
              .fontSize(10)
              .fontColor([$r('app.color.brand')])
            Text('内容由AI生成，请仔细甄别')
              .fontSize(10)
              .fontColor($r('app.color.brand'))
          }
          .width('100%')
          .margin({ top: 5 })
          .alignItems(VerticalAlign.Center)
        }
      } else if (item.status === 'error' && item.error.length > 0) {
        Text(item.error)
          .fontSize(12)
          .fontColor($r('app.color.warning'))
          .width('100%')
          .margin({ top: 7 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding({ left: 15, right: 15, top: 13, bottom: 13 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: this.adoptedEngineId === item.engineId ? 1.2 : 0.8,
      color: this.adoptedEngineId === item.engineId ? $r('app.color.brand') : $r('app.color.divider') })
    .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseOut })
      .combine(TransitionEffect.translate({ y: 10 })))
  }, (item: AggregateItem) => item.engineId + item.status + item.text.length.toString())

  if (this.loading) {
    Row({ space: 8 }) {
      LoadingProgress().width(14).height(14).color($r('app.color.font_tertiary'))
      Text('正在等待其余引擎返回')
        .fontSize(11)
        .fontColor($r('app.color.font_tertiary'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}

} else {
  this.singleResultSection()
  // AI 生成内容提示（合规）：译文框下方，蓝色告警字
  if (this.isAISelected() && this.resultText.length > 0) {
    Row({ space: 5 }) {
      SymbolGlyph($r('sys.symbol.AI'))
        .fontSize(12)
        .fontColor([$r('app.color.brand')])
      Text('内容由AI生成，请仔细甄别')
        .fontSize(11)
        .fontColor($r('app.color.brand'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
if (this.errMsg.length > 0) {
  Row({ space: 6 }) {
    SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
      .fontSize(14)
      .fontColor([$r('app.color.warning')])
    Text(this.errMsg)
      .fontSize(12)
      .fontColor($r('app.color.warning'))
      .layoutWeight(1)
  }
  .width('100%')
  .padding(12)
  .borderRadius(16)
  .backgroundColor($r('app.color.card_bg'))
  .border({ width: 0.8, color: $r('app.color.divider') })
  .alignItems(VerticalAlign.Top)
}
  }

  /** 无可用服务商引导卡：免费服务商默认关闭，首次使用引导去添加 */
  @Builder
  noEngineGuide() {
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

      Text('还没有可用的翻译服务')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_secondary'))
      Text('添加免费服务商或你自己的服务商后即可翻译')
        .fontSize(12)
        .fontColor($r('app.color.font_tertiary'))
        .textAlign(TextAlign.Center)

      Button('去添加服务商')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.brand'))
        .borderRadius(999)
        .padding({ left: 18, right: 18, top: 9, bottom: 9 })
        .margin({ top: 4 })
        .onClick(() => {
          this.addPanelShow = true;
        })
    }
    .width('100%')
    // 宽屏与输入卡等高（md 320 / lg 420），内容垂直居中
    .constraintSize({ minHeight: this.isLg() ? 420 : (this.isMd() ? 320 : 0) })
    .justifyContent(this.isWide() ? FlexAlign.Center : FlexAlign.Start)
    .padding({ top: 24, bottom: 24 })
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Center)
  }

  /** 单引擎结果卡（常驻：空态 / 加载中 / 已出译文）。
   *  宽屏空态/加载态给 320vp 最小高（内容垂直居中），避免右列 vs 左列小薄片失衡；
   *  有译文时卡片自然增长 */
  @Builder
  singleResultSection() {
    Column() {
      if (this.loading && this.resultText.length === 0) {
        Row({ space: 10 }) {
          LoadingProgress().width(20).height(20).color($r('app.color.brand'))
          Text(this.isAISelected() ? 'AI 翻译生成中' : '翻译中')
            .fontSize(14)
            .fontColor($r('app.color.font_secondary'))
        }
        .width('100%')
        .padding({ top: 26, bottom: 26 })
        .justifyContent(FlexAlign.Center)
      } else if (this.resultText.length > 0) {
        if (this.loading) {
          // 流式生成中：语言对标签 + 已生成的增量文本（随 onDelta 实时增长）
          Row() {
            Text(this.isAISelected() ? '流式生成中' : '翻译中')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.brand'))
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(999)
              .backgroundColor($r('app.color.emphasize_bg_light'))
            Blank()
          }
          .width('100%')
        } else {
          Row() {
            Text(TranslateUseCase.describePair(this.detectedFrom.length > 0
              && this.fromLang === AUTO_DETECT ? this.detectedFrom : this.fromLang, this.toLang))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.brand'))
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(999)
              .backgroundColor($r('app.color.emphasize_bg_light'))
            Blank()
            if (this.resultMeta.length > 0) {
              Text(this.resultMeta)
                .fontSize(11)
                .fontColor($r('app.color.font_tertiary'))
            }
          }
          .width('100%')
        }

        Text(this.resultText)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .lineHeight(26)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
          .margin({ top: 10 })
          .copyOption(CopyOptions.LocalDevice)
          .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 10 })))

        // 朗读 / 复制 / 重译：与输入框工具按钮同款等宽样式
        Row({ space: 8 }) {
          this.resultSpeakButton()
          this.resultAction($r('sys.symbol.plus_square_on_square'), '复制', (): void => {
            this.copyText(this.resultText);
          })
          this.resultAction($r('sys.symbol.play_arrow_triangle_2_circlepath'), '重译', (): void => {
            this.runTranslate();
          })
        }
        .width('100%')
        .margin({ top: 14 })
      } else {
        Column({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.doc'))
            .fontSize(28)
            .fontColor([$r('app.color.font_fourth')])
          Text('输入内容后点「翻译」，译文将显示在这里')
            .fontSize(12)
            .fontColor($r('app.color.font_tertiary'))
        }
        .width('100%')
        .padding({ top: 22, bottom: 22 })
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    // 宽屏空态/加载态与输入卡等高（md 320 / lg 420，内容垂直居中）；有译文时自然增高
    .constraintSize({
      minHeight: this.isWide() && this.resultText.length === 0
        ? (this.isLg() ? 420 : 320) : 0
    })
    .justifyContent(this.isWide() && this.resultText.length === 0 && !this.loading
      ? FlexAlign.Center : FlexAlign.Start)
    .padding(16)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 图片来源选择弹窗：白色圆角容器内左右两张浅灰图标卡片（拍照/相册），底部通栏「取消」。
 * customStyle 全自绘，浮在蒙层上；点卡片回调后关闭，点取消或蒙层收起。
 */
@CustomDialog
struct ImageSourceDialog {
  controller?: CustomDialogController;
  onPick: (source: string) => void = (source: string): void => {};

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        this.sourceCard($r('sys.symbol.camera'), '拍照', 'camera')
        this.sourceCard($r('sys.symbol.picture'), '相册', 'gallery')
      }
      .width('100%')

      // 取消按钮：通栏，与卡片同款浅灰
      Text('取消')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(44)
        .borderRadius(20)
        .backgroundColor($r('app.color.bg_container'))
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(16)
    .width(328)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(24)
  }

  @Builder
  sourceCard(icon: Resource, label: string, source: string) {
    Column({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(34)
        .fontColor([$r('app.color.brand')])
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(104)
    .borderRadius(20)
    .backgroundColor($r('app.color.bg_container'))
    .onClick(() => {
      this.controller?.close();
      this.onPick(source);
    })
  }
}
