/**
 * 图片翻译页（NavDestination 二级页）：
 * 上半屏图片（返回/保存到相册/重选/重拍），下半屏 bindSheet 半模态翻译面板。
 * 面板三档拖拽（detents + dragBar 小白条）：最低档仅露拖拽条≈图片全屏，
 * 中档 60%（进入默认），最高档近全屏≈翻译窗口全屏。
 * 面板布局对齐主页翻译界面：语言条（源=自动检测OCR，目标=Select）+ 引擎行 + 原文卡 + 译文卡。
 * 进入即端侧 OCR + 自动翻译；页面销毁时照片即焚（释放 PixelMap）。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { textRecognition } from '@kit.CoreVisionKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { PluginOcrEngine } from '../services/plugin/PluginOcrEngine';
import { devLogStore } from '../services/DevLogStore';
import { splitServiceRef } from '../services/plugin/ManggoTypes';
import {
  AUTO_DETECT,
  LangCode,
  LANGUAGE_LIST,
  LanguageItem,
  langLabel,
  TranslateStyle
} from '../models/TranslationTypes';
import { EngineRegistry } from '../services/EngineRegistry';
import { TranslateUseCase, TranslateExtra } from '../services/TranslateUseCase';
import { settingsStore } from '../services/SettingsStore';
import { OFFLINE_ENGINE_ID } from '../services/OfflineTranslator';
import { SpeechService } from '../services/SpeechService';
import { TransImageStore } from '../utils/TransImageStore';
import { AGGREGATE_ID, EngineSelector, PILL_VERSION_KEY } from '../components/EngineSelector';
import { AddProviderPanel } from '../components/AddProviderPanel';
import { captureFromCamera, pickFromGallery } from '../utils/ImagePickerUtil';

/** 路由参数：PixelMap 引用 + 面板初始状态（由翻译主页构造，页面销毁时负责释放） */
export interface ImageTransParam {
  pm: image.PixelMap;
  /** 照片来自相机且「拍照保存到相册」开启：图片区展示 SaveButton */
  canSave: boolean;
  toLang: LangCode;
  engineId: string;
  style: TranslateStyle;
}

/** 面板最低档高度（vp）：仅露拖拽条与少量内容，近似「图片全屏」 */
const SHEET_PEEK_VP = 120;

@Component
export struct ImageTranslatePage {
  /** 路由参数（Index PageMap 构造时传入） */
  session: ImageTransParam | null = null;
  /** 路由栈（Index Navigation 提供），返回/跳配置页 */
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 当前图片（展示与 OCR 共用，页面销毁时释放） */
  @State imgPm: image.PixelMap | null = null;
  @State imgCanSave: boolean = false;
  /** 面板原文（可编辑）与译文 */
  @State imgInput: string = '';
  @State imgResult: string = '';
  @State imgResultMeta: string = '';
  @State imgDetectedFrom: LangCode = '';
  @State imgOcrRunning: boolean = false;
  @State imgTranslating: boolean = false;
  @State imgErr: string = '';
  /** 面板内目标语言/引擎：临时状态，不写回主页偏好 */
  @State imgToLang: LangCode = 'en';
  @State imgEngineId: string = 'edge';
  /** 面板朗读状态：'' | 'playing' | 'paused' */
  @State imgSpeakInState: string = '';
  @State imgSpeakOutState: string = '';
  /** 半模态面板显示状态（bindSheet $$ 双向绑定） */
  @State isShow: boolean = false;
  /** 添加服务商面板显示状态（打开时收起半模态，避免层级遮挡） */
  @State addPanelShow: boolean = false;
  /** AI 风格指令（跟随主页当前选择） */
  style: TranslateStyle = 'plain';
  /** 沉浸式避让高度（vp） */
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  /** 窗口宽度（vp）：≥600 宽屏下面板限宽 */
  @StorageProp('ux_winW') winW: number = 0;
  /** 引擎行版本号：面板开关内置通道等变更后自愈面板当前引擎 */
  @StorageProp('ux_pill_version') @Watch('onPillsChanged') pillVersion: number = 0;
  private imgRunSeq: number = 0;
  /** 当前照片的历史 meta JSON（缩略图 + 沙箱原图副本路径）：OCR 成功后生成，随历史记录入库 */
  private imgHistoryMeta: string = '';

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 引擎行变更（添加面板开关内置通道/服务开关）后，校正面板当前引擎 */
  private onPillsChanged(): void {
    if (this.imgEngineId === AGGREGATE_ID) {
      return;
    }
    const ids = TranslateUseCase.usableEngineIds();
    if (!ids.includes(this.imgEngineId)) {
      this.imgEngineId = ids.length > 0 ? ids[0] : 'edge';
    }
  }

  aboutToAppear(): void {
    const p = this.session;
    if (p !== null) {
      this.imgPm = p.pm;
      this.imgCanSave = p.canSave;
      this.imgToLang = p.toLang;
      this.imgEngineId = p.engineId;
      this.style = p.style;
    }
  }

  /** 页面销毁：终止朗读、照片即焚 */
  private cleanup(): void {
    this.stopImgSpeech();
    const old = this.imgPm;
    this.imgPm = null;
    if (old !== null) {
      try {
        void old.release();
      } catch (e) {
        // 已释放时忽略
      }
    }
  }

  // ---- 触发 ----

  /** 端侧 OCR：识别结果填入面板原文并自动翻译（进入页面/换图后自动调用）。
   *  文字识别服务选了插件时走插件 ocr（query.image 传 JPEG base64），否则用系统端侧识别。 */
  private async runImgOcr(): Promise<void> {
    const pm = this.imgPm;
    if (pm === null || this.imgOcrRunning) {
      return;
    }
    this.imgOcrRunning = true;
    this.imgErr = '';
    try {
      this.toast('正在识别图片文字');
      const ocrEngineId = settingsStore.getOcrEngineId();
      let text = '';
      if (ocrEngineId.startsWith('plugin-')) {
        const helper = new util.Base64Helper();
        const ocrRef = ocrEngineId.substring('plugin-'.length);
        if (ocrRef.indexOf('#') >= 0) {
          // Manggo 插件 OCR：PixelMap → PNG base64 → recognize(base64, language, options)
          const parts = splitServiceRef(ocrRef);
          const packerM = image.createImagePacker();
          const packedM = await packerM.packToData(pm, { format: 'image/png', quality: 100 });
          const pngB64 = helper.encodeToStringSync(new Uint8Array(packedM));
          text = await PluginOcrEngine.recognizeManggo(parts.pluginId, parts.serviceId, pngB64, 'auto');
        } else {
          // Bob 插件 OCR：PixelMap → JPEG base64 → ocr(query, completion)
          const packer = image.createImagePacker();
          const packed = await packer.packToData(pm, { format: 'image/jpeg', quality: 90 });
          const imageB64 = helper.encodeToStringSync(new Uint8Array(packed));
          const info = await pm.getImageInfo();
          text = await PluginOcrEngine.recognize(ocrRef, imageB64,
            'auto', info.size.width, info.size.height);
        }
      } else {
        const visionInfo: textRecognition.VisionInfo = { pixelMap: pm };
        const config: textRecognition.TextRecognitionConfiguration = {
          isDirectionDetectionSupported: true
        };
        const recognition = await textRecognition.recognizeText(visionInfo, config);
        text = recognition.value.trim();
      }
      text = text.trim();
      if (text.length === 0) {
        this.imgErr = '未识别到图片中的文字，可换一张更清晰的图片或手动输入';
        return;
      }
      this.imgInput = text;
      // 生成历史 meta（240px 缩略图 + 沙箱 1080px 原图副本）：后台进行，不阻断翻译
      TransImageStore.makeMeta(getContext(this) as common.Context, pm)
        .then((meta: string): void => {
          this.imgHistoryMeta = meta;
        });
      this.runImgTranslate();
    } catch (e) {
      this.imgErr = '识别失败：' + this.errText(e);
      devLogStore.append('error', 'ocr', '图片识别失败：' + this.errText(e));
    } finally {
      this.imgOcrRunning = false;
    }
  }

  /** 面板翻译：源语言固定自动检测，走与主页相同的翻译管线（含敏感词拦截与历史记录） */
  private async runImgTranslate(): Promise<void> {
    const text = this.imgInput.trim();
    if (text.length === 0 || this.imgTranslating) {
      return;
    }
    this.imgTranslating = true;
    this.imgErr = '';
    this.imgResult = '';
    const seq = ++this.imgRunSeq;
    try {
      const extra: TranslateExtra = { recordType: 1, meta: this.imgHistoryMeta };
      const result = await TranslateUseCase.translate(text, AUTO_DETECT, this.imgToLang,
        this.imgEngineId, this.style, extra);
      if (seq !== this.imgRunSeq) {
        return;
      }
      this.imgResult = result.text;
      this.imgDetectedFrom = result.detectedFrom ?? '';
      const pair = TranslateUseCase.describePair(result.detectedFrom ?? AUTO_DETECT, this.imgToLang);
      this.imgResultMeta = this.engineLabel(this.imgEngineId) + ' · ' + pair;
    } catch (e) {
      if (seq !== this.imgRunSeq) {
        return;
      }
      this.imgErr = '翻译失败：' + this.errText(e);
    } finally {
      if (seq === this.imgRunSeq) {
        this.imgTranslating = false;
      }
    }
  }

  /** 图片区重拍/重选：换图后复位面板并重新识别 */
  private async rePick(source: string): Promise<void> {
    if (this.imgOcrRunning) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const pm = source === 'camera' ? await captureFromCamera(ctx) : await pickFromGallery(ctx);
      if (pm === null) {
        return; // 用户取消
      }
      this.stopImgSpeech();
      this.imgErr = '';
      this.imgInput = '';
      this.imgResult = '';
      this.imgResultMeta = '';
      this.imgDetectedFrom = '';
      this.imgSpeakInState = '';
      this.imgSpeakOutState = '';
      this.imgHistoryMeta = '';
      const old = this.imgPm;
      this.imgPm = pm;
      this.imgCanSave = source === 'camera' && settingsStore.getOcrSaveToGallery();
      if (old !== null) {
        try {
          void old.release();
        } catch (e) {
          // 已释放时忽略
        }
      }
      this.runImgOcr();
    } catch (e) {
      this.toast((source === 'camera' ? '拍照失败：' : '选择图片失败：') + this.errText(e));
    }
  }

  /** 面板选择目标语言：已有原文时立即重译（对齐有道换语言即翻的预期） */
  private pickImgTo(code: LangCode): void {
    if (code === this.imgToLang) {
      return;
    }
    this.stopImgSpeech();
    this.imgToLang = code;
    if (this.imgInput.trim().length > 0) {
      this.runImgTranslate();
    }
  }

  /** 面板切换引擎：已有原文时立即重译（仅面板内生效，不改主页引擎） */
  private pickImgEngine(id: string): void {
    if (id === this.imgEngineId) {
      return;
    }
    this.stopImgSpeech();
    this.imgEngineId = id;
    if (this.imgInput.trim().length > 0) {
      this.runImgTranslate();
    }
  }

  /** 引擎行拖拽排序落位：chip 顺序组件已落盘，此处同步服务列表（聚合返回）顺序 */
  private async reorderService(fromId: string, toId: string): Promise<void> {
    await settingsStore.reorderService(fromId, toId);
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 关闭（停用）：内置免费通道走删除开关存储，用户服务走服务列表开关；均可在添加面板恢复 */
  private async disableService(id: string): Promise<void> {
    const adapter = EngineRegistry.byId(id);
    if (id === OFFLINE_ENGINE_ID) {
      // 离线翻译：× = 关总开关，可在「离线翻译」管理页重新开启
      await settingsStore.setOfflineEnabled(false);
    } else if (EngineRegistry.isBuiltin(id)) {
      // 引擎行 × = 停用：保留在「翻译服务」管理页（已添加），仅从引擎行/聚合隐藏
      await settingsStore.setBuiltinEnabled(
        settingsStore.getBuiltinEnabled().filter((e: string): boolean => e !== id));
    } else {
      await settingsStore.setServiceEnabled(id, false);
    }
    TranslateUseCase.refreshServices();
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    const ids = TranslateUseCase.usableEngineIds();
    if (!ids.includes(this.imgEngineId)) {
      this.imgEngineId = ids.length > 0 ? ids[0] : 'edge';
    }
    const hint = id === OFFLINE_ENGINE_ID ? '可在「离线翻译」页重新启用' : '可在「翻译服务」管理页重新启用或删除';
    this.toast('已停用 ' + (adapter !== undefined ? adapter.label : id) + '，' + hint);
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

  /** SaveButton 点击回调：安全控件已授予临时媒体库写权限，此处把当前照片落库 */
  private async onSaveButtonClick(result: SaveButtonOnClickResult): Promise<void> {
    const pm = this.imgPm;
    if (pm === null) {
      return;
    }
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      this.toast('本次未获得保存授权（' + result + '）');
      return;
    }
    let file: fs.File | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(getContext(this));
      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      packer = image.createImagePacker();
      const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 92 };
      await packer.packToFile(pm, file.fd, packOpts);
      this.imgCanSave = false;
      this.toast('照片已保存到相册');
    } catch (e) {
      this.toast('保存到相册失败：' + this.errText(e));
    } finally {
      if (packer !== null) {
        packer.release();
      }
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  /** 面板朗读终止（切语言/切引擎/页面销毁时复位按钮状态） */
  private stopImgSpeech(): void {
    if (this.imgSpeakInState !== '' || this.imgSpeakOutState !== '') {
      SpeechService.stopSpeak();
      this.imgSpeakInState = '';
      this.imgSpeakOutState = '';
    }
  }

  /** 朗读语言支持判定：按当前 TTS 服务（系统仅中英；插件按其声明） */
  private ttsSupported(code: string): boolean {
    return SpeechService.isLangSupported(code);
  }

  /** 面板原文朗读语言：OCR 不产出语种，用翻译检测结果，未检测过视为中文 */
  private imgInputLangTag(): string {
    return this.imgDetectedFrom.length > 0 ? this.imgDetectedFrom : 'zh';
  }

  private imgSpeakInLabel(): string {
    if (this.imgSpeakInState === 'playing') {
      return '暂停';
    }
    if (this.imgSpeakInState === 'paused') {
      return '继续';
    }
    return this.ttsSupported(this.imgInputLangTag()) ? '朗读' : '不支持';
  }

  /** 面板原文朗读：播放中点=暂停，暂停中点=继续 */
  private async speakImgInput(): Promise<void> {
    if (this.imgSpeakInState === 'playing') {
      this.imgSpeakInState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.imgSpeakInState === 'paused') {
      this.imgSpeakInState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    const text = this.imgInput.trim();
    if (text.length === 0) {
      this.toast('没有可朗读的内容');
      return;
    }
    const lang = this.imgInputLangTag();
    if (!this.ttsSupported(lang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    this.imgSpeakOutState = '';
    this.imgSpeakInState = 'playing';
    try {
      await SpeechService.speak(text, lang, 'ocr_input', (): void => {
        this.imgSpeakInState = '';
      });
    } catch (e) {
      this.imgSpeakInState = '';
      this.toast('朗读启动失败：' + this.errText(e));
    }
  }

  /** 面板译文朗读 */
  private async speakImgResult(): Promise<void> {
    if (this.imgSpeakOutState === 'playing') {
      this.imgSpeakOutState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.imgSpeakOutState === 'paused') {
      this.imgSpeakOutState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    if (this.imgResult.length === 0) {
      return;
    }
    if (!this.ttsSupported(this.imgToLang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    this.imgSpeakInState = '';
    this.imgSpeakOutState = 'playing';
    try {
      await SpeechService.speak(this.imgResult, this.imgToLang, 'ocr_result', (): void => {
        this.imgSpeakOutState = '';
      });
    } catch (e) {
      this.imgSpeakOutState = '';
      this.toast('朗读启动失败：' + this.errText(e));
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

  // ---- 面板数据源 ----

  /** 引擎显示名（结果 meta 用） */
  private engineLabel(id: string): string {
    const hit = EngineRegistry.byId(id);
    return hit !== undefined ? hit.label : id;
  }

  /** 面板当前引擎是否 AI（等待文案区分） */
  private isImgAI(): boolean {
    const hit = EngineRegistry.byId(this.imgEngineId);
    return hit !== undefined && hit.isAI;
  }

  /** 面板源语言下方说明：检测到语种后展示 */
  private imgFromCaption(): string {
    if (this.imgDetectedFrom.length > 0) {
      return '已识别：' + langLabel(this.imgDetectedFrom);
    }
    return this.imgOcrRunning ? '正在识别' : '识别后自动检测语言';
  }

  /** 面板目标语言下拉数据源（与主页语言表同源） */
  private imgToOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const it of LANGUAGE_LIST) {
      opts.push({ value: it.label });
    }
    return opts;
  }

  private imgToIndex(): number {
    return LANGUAGE_LIST.findIndex((it: LanguageItem): boolean => it.code === this.imgToLang);
  }

  // ---- UI ----

  build() {
    NavDestination() {
      Stack() {
        // 图片层 + 顶部按钮（半模态的宿主节点）
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.imgPm !== null) {
            Image(this.imgPm)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .autoResize(true)
          }
          Row({ space: 10 }) {
            this.overlayCircleButton($r('sys.symbol.chevron_left'), (): void => {
              this.pathStack.pop();
            })
            Blank()
            if (this.imgCanSave) {
              SaveButton({
                icon: SaveIconStyle.FULL_FILLED,
                text: SaveDescription.SAVE_IMAGE,
                buttonType: ButtonType.Capsule
              })
                .onClick((event: ClickEvent, result: SaveButtonOnClickResult): void => {
                  this.onSaveButtonClick(result);
                })
            }
            this.overlayCircleButton($r('sys.symbol.picture'), (): void => {
              this.rePick('gallery');
            })
            this.overlayCircleButton($r('sys.symbol.camera'), (): void => {
              this.rePick('camera');
            })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: this.statusBarH + 10 })
          .alignItems(VerticalAlign.Center)

          // 面板收起后：图片底部小把手，点击重新拉起翻译面板
          if (!this.isShow) {
            Column() {
              Blank()
              Row() {
                Row()
                  .width(44)
                  .height(5)
                  .borderRadius(3)
                  .backgroundColor('rgba(255,255,255,0.75)')
              }
              .width(96)
              .height(30)
              .justifyContent(FlexAlign.Center)
              .margin({ bottom: this.navBarH + 10 })
              .onClick(() => {
                this.isShow = true;
              })
            }
            .width('100%')
            .height('100%')
            // 自身不吃触摸事件：空白区域穿透到图片/顶栏，只有把手可点
            .hitTestBehavior(HitTestMode.None)
            .transition(TransitionEffect.OPACITY.animation({ duration: 200 })
              .combine(TransitionEffect.translate({ y: 20 })))
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        // 宿主挂载后再拉起半模态（官方约束：宿主未上树时 isShow=true 不生效），随即开始识别
        .onAppear((): void => {
          this.isShow = true;
          this.runImgOcr();
        })
        // 半模态翻译面板：三档拖拽（小白条把手自动显示）
        .bindSheet($$this.isShow, this.panelBuilder(), {
          detents: [SHEET_PEEK_VP, SheetSize.MEDIUM, SheetSize.LARGE],
          detentSelection: SheetSize.MEDIUM,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          // 不用系统悬浮 ✕（会压在内容右上角），关闭按钮做进语言行里
          showClose: false,
          // 不加蒙层：面板打开时图片区的返回/重拍/重选按钮仍可点
          enableOutsideInteractive: true,
          backgroundColor: $r('app.color.card_bg'),
          width: this.winW >= 600 ? 640 : '100%',
          // 拖动换挡过程中持续刷新内容区（默认 FOLLOW_DETENT 是拖完才刷新，会出现大片空白）
          scrollSizeMode: ScrollSizeMode.CONTINUOUS,
          onWillDismiss: (action: DismissSheetAction): void => {
            if (action.reason === DismissReason.SLIDE_DOWN) {
              // 最低档再下拉不关闭，防误滑丢结果
              return;
            }
            // 返回键/侧滑：随页面一起回翻译主页（pop 会带走半模态）
            this.pathStack.pop();
          }
        })

      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      // 添加服务商半模态（bindSheet 挂载）：先收起本页半模态避免层级冲突。
      // $$ 双向绑定：蒙层/下拉/返回关闭时系统回写 addPanelShow，状态不残留；
      // onDisappear 兜底恢复本页半模态（交互关闭不经过 onClose）
      .bindSheet($$this.addPanelShow, this.addSheetBuilder(), {
        height: SheetSize.FIT_CONTENT,
        showClose: false,
        // 官方推荐：<600vp 底部弹出，md/lg 大屏自动适配居中跟手弹窗
        preferType: SheetType.POPUP,
        backgroundColor: $r('app.color.card_bg'),
        onDisappear: (): void => {
          this.isShow = true;
        }
      })
    }
    .hideTitleBar(true)
    .onWillDisappear((): void => {
      this.isShow = false;
    })
    .onDisAppear((): void => {
      this.cleanup();
    })
  }

  /** 添加服务商半模态内容（限宽居中，适配平板全宽 sheet） */
  @Builder
  addSheetBuilder() {
    Column() {
      AddProviderPanel({
        onClose: (): void => {
          this.addPanelShow = false;
          this.isShow = true;
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

  /** 图片区顶部圆形按钮：半透明黑底白图标（深色图片区上可读） */
  @Builder
  overlayCircleButton(icon: Resource, onTap: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([$r('sys.color.ohos_id_color_text_primary_contrary')])
    }
    .width(38)
    .height(38)
    .borderRadius(19)
    .backgroundColor('rgba(0,0,0,0.45)')
    .onClick(() => {
      onTap();
    })
  }

  /** 半模态面板内容：语言条 + 引擎行 + 原文卡 + 译文卡 + 错误提示 */
  @Builder
  panelBuilder() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          // 语言行：✕（收起面板）+ 源语言固定「自动检测（OCR）」+ 目标语言 Select
          Row({ space: 10 }) {
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([$r('app.color.font_secondary')])
            }
            .width(30)
            .height(30)
            .borderRadius(15)
            .backgroundColor($r('app.color.bg_container'))
            .onClick(() => {
              // 收起面板看图，不退页（底部把手可再拉起）
              this.isShow = false;
            })

            Column({ space: 2 }) {
              Text('自动检测（OCR）')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
              if (this.imgOcrRunning) {
                Row({ space: 5 }) {
                  LoadingProgress().width(11).height(11).color($r('app.color.font_tertiary'))
                  Text('正在识别')
                    .fontSize(11)
                    .fontColor($r('app.color.font_tertiary'))
                }
                .alignItems(VerticalAlign.Center)
              } else {
                Text(this.imgFromCaption())
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Select(this.imgToOptions())
              .selected(this.imgToIndex())
              .value(langLabel(this.imgToLang))
              .font({ size: 15, weight: FontWeight.Medium })
              .fontColor($r('app.color.font_primary'))
              .selectedOptionFont({ size: 14 })
              .optionFont({ size: 14 })
              .width(128)
              .onSelect((index: number): void => {
                if (index >= 0 && index < LANGUAGE_LIST.length) {
                  this.pickImgTo(LANGUAGE_LIST[index].code);
                }
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 引擎行：与主页同款（面板内隐藏聚合 chip）
          EngineSelector({
            engineId: this.imgEngineId,
            showAggregate: false,
            onPick: (id: string): void => this.pickImgEngine(id),
            onReorder: (fromId: string, toId: string): void => {
              this.reorderService(fromId, toId);
            },
            onDisable: (id: string): void => {
              this.disableService(id);
            },
            onAdd: (): void => {
              // 半模态层级高于页面内容：先收起面板再弹添加面板，关闭后恢复
              this.isShow = false;
              this.addPanelShow = true;
            }
          })

          // 原文卡：识别内容可编辑 + 朗读/复制
          Column() {
            Text('原文')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.font_secondary'))
            if (this.imgOcrRunning) {
              Row({ space: 10 }) {
                LoadingProgress().width(18).height(18).color($r('app.color.brand'))
                Text('正在识别图片文字')
                  .fontSize(13)
                  .fontColor($r('app.color.font_secondary'))
              }
              .width('100%')
              .padding({ top: 26, bottom: 26 })
              .justifyContent(FlexAlign.Center)
            } else {
              TextArea({ placeholder: '未识别到文字？可在此手动输入', text: this.imgInput })
                .placeholderFont({ size: 14 })
                .placeholderColor($r('app.color.font_fourth'))
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
                .backgroundColor(Color.Transparent)
                  // 官方说明：输入框 left/right padding 为 0 时，光标可能被默认圆角裁剪区截断，显式清零（harmonyos-references/ts-basic-components-textinput）
                  .borderRadius(0)
                .constraintSize({ minHeight: 72, maxHeight: 150 })
                .padding({ left: 0, right: 0, top: 12, bottom: 6 })
                .includeFontPadding(true)
                .width('100%')
                .onChange((value: string): void => {
                  this.imgInput = value;
                })
            }
            Row({ space: 8 }) {
              this.imgSpeakInButton()
              this.imgActionButton($r('sys.symbol.plus_square_on_square'), '复制', (): void => {
                this.copyText(this.imgInput);
              })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor($r('app.color.bg_container'))
          .border({ width: 0.8, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)

          // 译文卡：朗读/复制/重译（首次出译文前按钮文案为「翻译」）
          Column() {
            Row() {
              Text('译文')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
              Blank()
              if (this.imgResultMeta.length > 0) {
                Text(this.imgResultMeta)
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width('100%')

            if (this.imgTranslating) {
              Row({ space: 10 }) {
                LoadingProgress().width(18).height(18).color($r('app.color.brand'))
                Text(this.isImgAI() ? 'AI 翻译生成中' : '翻译中')
                  .fontSize(13)
                  .fontColor($r('app.color.font_secondary'))
              }
              .width('100%')
              .padding({ top: 26, bottom: 26 })
              .justifyContent(FlexAlign.Center)
            } else if (this.imgResult.length > 0) {
              Text(this.imgResult)
                .fontSize(15)
                .lineHeight(24)
                .fontColor($r('app.color.font_primary'))
                .width('100%')
                .margin({ top: 8 })
                .copyOption(CopyOptions.LocalDevice)
            } else {
              Text(this.imgInput.trim().length > 0 ? '点「翻译」开始翻译' : '识别内容后将显示译文')
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
                .width('100%')
                .margin({ top: 14 })
            }

            Row({ space: 8 }) {
              this.imgSpeakOutButton()
              this.imgActionButton($r('sys.symbol.plus_square_on_square'), '复制', (): void => {
                this.copyText(this.imgResult);
              })
              this.imgActionButton($r('sys.symbol.play_arrow_triangle_2_circlepath'),
                this.imgResult.length > 0 ? '重译' : '翻译', (): void => {
                  this.runImgTranslate();
                })
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor($r('app.color.bg_container'))
          .border({ width: 0.8, color: $r('app.color.divider') })
          .alignItems(HorizontalAlign.Start)

          // 错误提示（OCR 失败 / 翻译失败 / 未识别到文字）
          if (this.imgErr.length > 0) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
                .fontSize(14)
                .fontColor([$r('app.color.warning')])
              Text(this.imgErr)
                .fontSize(12)
                .fontColor($r('app.color.warning'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .borderRadius(14)
            .backgroundColor($r('app.color.bg_container'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(VerticalAlign.Top)
          }

          Text('OCR 支持中英日韩 · 端侧识别，图片不上传')
            .fontSize(10)
            .fontColor($r('app.color.font_fourth'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 16 + this.navBarH })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
  }

  /** 面板内操作按钮：与主页结果卡同款，底色用卡片白（面板卡片是浅灰） */
  @Builder
  imgActionButton(icon: Resource, label: string, onTap: () => void) {
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
    .backgroundColor($r('app.color.card_bg'))
    .onClick(() => {
      onTap();
    })
  }

  /** 面板原文朗读按钮：播放中=「暂停」/ 暂停中=「继续」/ 语言不支持=置灰「不支持」 */
  @Builder
  imgSpeakInButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.imgSpeakInState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(16)
        .fontColor(this.imgSpeakInState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')] : [$r('app.color.font_secondary')])
      Text(this.imgSpeakInLabel())
        .fontSize(12)
        .fontColor(this.imgSpeakInState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.imgInputLangTag())
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor(this.imgSpeakInState !== '' ? $r('app.color.brand') : $r('app.color.card_bg'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakImgInput();
    })
  }

  /** 面板译文朗读按钮 */
  @Builder
  imgSpeakOutButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.imgSpeakOutState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(15)
        .fontColor(this.imgSpeakOutState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')]
          : (this.ttsSupported(this.imgToLang)
            ? [$r('app.color.font_secondary')] : [$r('app.color.font_fourth')]))
      Text(this.imgSpeakOutState === 'playing' ? '暂停'
        : (this.imgSpeakOutState === 'paused' ? '继续'
          : (this.ttsSupported(this.imgToLang) ? '朗读' : '不支持')))
        .fontSize(12)
        .fontColor(this.imgSpeakOutState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.imgToLang)
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor(this.imgSpeakOutState !== '' ? $r('app.color.brand') : $r('app.color.card_bg'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakImgResult();
    })
  }
}
