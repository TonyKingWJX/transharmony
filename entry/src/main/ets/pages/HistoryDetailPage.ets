/**
 * 历史详情二级页（NavDestination，对齐主翻译页视觉）：
 * - 文本记录：语言条（只读展示）+ 引擎/时间行 + 原文卡（可编辑）+ 译文卡
 * - 图片记录：顶部缩略图（历史入库的 240px JPEG；无图时占位提示「照片已销毁」）
 *   + 识别原文卡 + 译文卡
 * 支持编辑原文后重译（走 TranslateUseCase，新结果自动入历史，图片记录保留原缩略图）、
 * 原文/译文朗读（TTS 中英，其余置灰）、复制、收藏星标。
 * 进入方式：历史页卡片点击（Index 注入回调推栈）。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { langLabel } from '../models/TranslationTypes';
import { historyStore, HistoryItem } from '../services/HistoryStore';
import { TranslateUseCase, TranslateExtra } from '../services/TranslateUseCase';
import { EngineRegistry } from '../services/EngineRegistry';
import { SpeechService } from '../services/SpeechService';
import { TransImageStore, HistoryImageMeta } from '../utils/TransImageStore';

/** 路由参数：历史记录 id */
export interface HistoryDetailParam {
  id: number;
}

@Component
export struct HistoryDetailPage {
  /** 路由参数（Index PageMap 构造时传入） */
  recordId: number = 0;
  /** 路由栈（Index Navigation 提供） */
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 记录加载完成 */
  @State loaded: boolean = false;
  /** 记录字段（source 可编辑） */
  @State source: string = '';
  @State result: string = '';
  @State engineId: string = '';
  @State fromLang: string = '';
  @State toLang: string = '';
  @State createdAt: number = 0;
  @State favorite: boolean = false;
  @State recordType: number = 0;
  /** 图片记录缩略图（PixelMap，由 meta base64 解码） */
  @State thumbPm: image.PixelMap | null = null;
  /** 原始 meta JSON（重译入历史时沿用原缩略图） */
  private rawMeta: string = '';
  /** 重译后的结果 meta（引擎 · 语言对） */
  @State resultMeta: string = '';
  @State translating: boolean = false;
  @State errMsg: string = '';
  /** 朗读状态：'' | 'playing' | 'paused' */
  @State speakInState: string = '';
  @State speakOutState: string = '';
  /** 沉浸式避让高度（vp） */
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  /** 窗口宽度（vp）：≥600 宽屏内容限宽 */
  @StorageProp('ux_winW') winW: number = 0;
  private runSeq: number = 0;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    // 离页终止朗读
    if (this.speakInState !== '' || this.speakOutState !== '') {
      SpeechService.stopSpeak();
    }
  }

  private async load(): Promise<void> {
    try {
      const item = await historyStore.getById(this.recordId);
      if (item === undefined) {
        this.toast('记录不存在或已删除');
        this.pathStack.pop();
        return;
      }
      this.fillFromItem(item);
      this.loaded = true;
    } catch (e) {
      this.toast('读取记录失败：' + this.errText(e));
      this.pathStack.pop();
    }
  }

  private fillFromItem(item: HistoryItem): void {
    this.source = item.source;
    this.result = item.result;
    this.engineId = item.engineId;
    this.fromLang = item.fromLang;
    this.toLang = item.toLang;
    this.createdAt = item.createdAt;
    this.favorite = item.favorite === 1;
    this.recordType = item.recordType;
    this.rawMeta = item.meta;
    this.resultMeta = this.resultMetaLine();
    this.decodeThumb(item.meta);
  }

  /** 引擎名 · 语言对（译文卡 meta 行） */
  private engineLine(id: string): string {
    return EngineRegistry.displayNameOf(id);
  }

  private pairLine(from: string, to: string): string {
    return langLabel(from) + ' → ' + langLabel(to);
  }

  private resultMetaLine(): string {
    return this.engineLine(this.engineId) + ' · ' + this.pairLine(this.fromLang, this.toLang);
  }

  /**
   * meta 解码图片：优先加载沙箱原图副本（imgPath），缺失/损坏时退回 base64 缩略图，
   * 都没有则保持 thumbPm=null（展示「照片已销毁」占位）。
   */
  private decodeThumb(meta: string): void {
    if (this.recordType !== 1 || meta.length === 0) {
      return;
    }
    let parsed: HistoryImageMeta | null = null;
    try {
      parsed = JSON.parse(meta) as HistoryImageMeta;
    } catch (e) {
      return;
    }
    const loadFromBase64 = (): void => {
      try {
        if (parsed === null || parsed.thumb.length === 0) {
          return;
        }
        const b64 = parsed.thumb.substring(parsed.thumb.indexOf(',') + 1);
        const bytes = new util.Base64Helper().decodeSync(b64);
        const src = image.createImageSource(bytes.buffer as ArrayBuffer);
        src.createPixelMap().then((pm: image.PixelMap): void => {
          this.thumbPm = pm;
          src.release();
        }).catch((): void => {
          src.release();
        });
      } catch (e) {
        // meta 损坏按无图处理
      }
    };
    // 沙箱原图优先（完整尺寸），失败退回缩略图
    if (parsed !== null && parsed.imgPath.length > 0) {
      const ctx = getContext(this) as common.Context;
      TransImageStore.loadPixelMap(ctx, parsed.imgPath).then((pm: image.PixelMap | null): void => {
        if (pm !== null) {
          this.thumbPm = pm;
        } else {
          loadFromBase64();
        }
      });
      return;
    }
    loadFromBase64();
  }

  // ---- 操作 ----

  /** 编辑原文后重译：自动检测源语言，新结果入历史（图片记录保留缩略图与类型） */
  private async retranslate(): Promise<void> {
    const text = this.source.trim();
    if (text.length === 0 || this.translating) {
      return;
    }
    this.translating = true;
    this.errMsg = '';
    this.result = '';
    const seq = ++this.runSeq;
    try {
      const extra: TranslateExtra = this.recordType === 1
        ? { recordType: 1, meta: this.rawMeta }
        : { recordType: 0, meta: '' };
      const result = await TranslateUseCase.translate(text, 'auto', this.toLang, this.engineId,
        'plain', extra);
      if (seq !== this.runSeq) {
        return;
      }
      this.result = result.text;
      this.fromLang = result.detectedFrom ?? this.fromLang;
      this.resultMeta = this.resultMetaLine();
      this.toast('已重新翻译并存入历史');
    } catch (e) {
      if (seq !== this.runSeq) {
        return;
      }
      this.errMsg = '翻译失败：' + this.errText(e);
    } finally {
      if (seq === this.runSeq) {
        this.translating = false;
      }
    }
  }

  private async copyText(text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('已复制');
  }

  private async toggleFavorite(): Promise<void> {
    const next = !this.favorite;
    await historyStore.setFavorite(this.recordId, next);
    this.favorite = next;
  }

  // ---- 朗读 ----

  private stopSpeech(): void {
    if (this.speakInState !== '' || this.speakOutState !== '') {
      SpeechService.stopSpeak();
      this.speakInState = '';
      this.speakOutState = '';
    }
  }

  /** 朗读语言支持判定：按当前 TTS 服务（系统仅中英；插件按其声明） */
  private ttsSupported(code: string): boolean {
    return SpeechService.isLangSupported(code);
  }

  /** 原文朗读语言：入库的 fromLang（检测结果），兜底中文 */
  private inputLangTag(): string {
    return this.fromLang.length > 0 ? this.fromLang : 'zh';
  }

  private speakInLabel(): string {
    if (this.speakInState === 'playing') {
      return '暂停';
    }
    if (this.speakInState === 'paused') {
      return '继续';
    }
    return this.ttsSupported(this.inputLangTag()) ? '朗读' : '不支持';
  }

  private async speakInput(): Promise<void> {
    if (this.speakInState === 'playing') {
      this.speakInState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.speakInState === 'paused') {
      this.speakInState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    const text = this.source.trim();
    if (text.length === 0) {
      this.toast('没有可朗读的内容');
      return;
    }
    const lang = this.inputLangTag();
    if (!this.ttsSupported(lang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    this.speakOutState = '';
    this.speakInState = 'playing';
    try {
      await SpeechService.speak(text, lang, 'history_in', (): void => {
        this.speakInState = '';
      });
    } catch (e) {
      this.speakInState = '';
      this.toast('朗读启动失败：' + this.errText(e));
    }
  }

  private async speakResult(): Promise<void> {
    if (this.speakOutState === 'playing') {
      this.speakOutState = 'paused';
      await SpeechService.pauseSpeak();
      return;
    }
    if (this.speakOutState === 'paused') {
      this.speakOutState = 'playing';
      await SpeechService.resumeSpeak();
      return;
    }
    if (this.result.length === 0) {
      return;
    }
    if (!this.ttsSupported(this.toLang)) {
      this.toast('当前语音服务不支持该语言');
      return;
    }
    this.speakInState = '';
    this.speakOutState = 'playing';
    try {
      await SpeechService.speak(this.result, this.toLang, 'history_out', (): void => {
        this.speakOutState = '';
      });
    } catch (e) {
      this.speakOutState = '';
      this.toast('朗读启动失败：' + this.errText(e));
    }
  }

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

  private timeText(): string {
    const d = new Date(this.createdAt);
    const p = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  // ---- UI ----

  build() {
    NavDestination() {
      Column() {
        // 自定义标题栏（与二级页群组一致：返回圆钮 + 标题 + 右侧星标）
        Row({ space: 10 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(18)
              .fontColor([$r('app.color.font_primary')])
          }
          .width(38)
          .height(38)
          .borderRadius(19)
          .backgroundColor($r('app.color.bg_container'))
          .border({ width: 0.8, color: $r('app.color.divider') })
          .onClick((): void => {
            this.pathStack.pop();
          })

          Text(this.recordType === 1 ? '图片翻译详情' : '翻译详情')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 收藏星标
          SymbolGlyph(this.favorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
            .fontSize(20)
            .fontColor([this.favorite ? $r('app.color.brand') : $r('app.color.font_tertiary')])
            .padding(8)
            .onClick((): void => {
              this.toggleFavorite();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: this.statusBarH + 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        if (this.loaded) {
          Scroll() {
            Column({ space: 10 }) {
              // 图片记录缩略图（图片已焚毁/未携带时不显示占位框）
              if (this.recordType === 1 && this.thumbPm !== null) {
                Image(this.thumbPm)
                  .width('100%')
                  .height(200)
                  .objectFit(ImageFit.Contain)
                  .borderRadius(16)
                  .backgroundColor('#000000')
              }

              // 语言条（只读）+ 时间
              Row() {
                Text(this.recordType === 1 ? '自动检测（OCR）' : this.pairLine(this.fromLang, this.toLang))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_primary'))
                Blank()
                Text(this.timeText())
                  .fontSize(11)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              // 原文卡：可编辑 + 朗读/复制
              Column() {
                Text(this.recordType === 1 ? '识别原文（OCR）' : '原文')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_secondary'))
                TextArea({ placeholder: '可编辑后重新翻译', text: this.source })
                  .placeholderFont({ size: 14 })
                  .placeholderColor($r('app.color.font_fourth'))
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
                  .backgroundColor(Color.Transparent)
                  .constraintSize({ minHeight: 72, maxHeight: 180 })
                  // 上下保留内边距 + includeFontPadding 防首行截断（对齐主页/图片页写法）
                  .padding({ left: 0, right: 0, top: 6, bottom: 6 })
                  .includeFontPadding(true)
                  .width('100%')
                  .onChange((value: string): void => {
                    this.source = value;
                  })
                Row({ space: 8 }) {
                  this.speakInButton()
                  this.actionButton($r('sys.symbol.plus_square_on_square'), '复制', (): void => {
                    this.copyText(this.source);
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

              // 译文卡：朗读/复制/重译
              Column() {
                Row() {
                  Text('译文')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.font_secondary'))
                  Blank()
                  if (this.resultMeta.length > 0) {
                    Text(this.resultMeta)
                      .fontSize(11)
                      .fontColor($r('app.color.font_tertiary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width('100%')

                if (this.translating) {
                  Row({ space: 10 }) {
                    LoadingProgress().width(18).height(18).color($r('app.color.brand'))
                    Text('翻译中')
                      .fontSize(13)
                      .fontColor($r('app.color.font_secondary'))
                  }
                  .width('100%')
                  .padding({ top: 26, bottom: 26 })
                  .justifyContent(FlexAlign.Center)
                } else if (this.result.length > 0) {
                  Text(this.result)
                    .fontSize(15)
                    .lineHeight(24)
                    .fontColor($r('app.color.font_primary'))
                    .width('100%')
                    .margin({ top: 8 })
                    .copyOption(CopyOptions.LocalDevice)
                } else {
                  Text('点「翻译」重新翻译')
                    .fontSize(12)
                    .fontColor($r('app.color.font_tertiary'))
                    .width('100%')
                    .margin({ top: 14 })
                }

                Row({ space: 8 }) {
                  this.speakOutButton()
                  this.actionButton($r('sys.symbol.plus_square_on_square'), '复制', (): void => {
                    this.copyText(this.result);
                  })
                  this.actionButton($r('sys.symbol.play_arrow_triangle_2_circlepath'),
                    this.result.length > 0 ? '重译' : '翻译', (): void => {
                      this.retranslate();
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

              // 错误提示
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
                .borderRadius(14)
                .backgroundColor($r('app.color.bg_container'))
                .border({ width: 0.8, color: $r('app.color.divider') })
                .alignItems(VerticalAlign.Top)
              }

              Text('编辑原文后点「重译」会生成一条新的历史记录')
                .fontSize(10)
                .fontColor($r('app.color.font_fourth'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ bottom: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 24 + this.navBarH })
            .constraintSize({ maxWidth: this.winW >= 840 ? 720 : (this.winW >= 600 ? 640 : 100000) })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 操作按钮：与图片翻译面板/主页结果卡同款 */
  @Builder
  actionButton(icon: Resource, label: string, onTap: () => void) {
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

  /** 原文朗读按钮：播放中=「暂停」/ 暂停中=「继续」/ 语言不支持=置灰「不支持」 */
  @Builder
  speakInButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.speakInState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(16)
        .fontColor(this.speakInState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')] : [$r('app.color.font_secondary')])
      Text(this.speakInLabel())
        .fontSize(12)
        .fontColor(this.speakInState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.inputLangTag())
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor(this.speakInState !== '' ? $r('app.color.brand') : $r('app.color.card_bg'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakInput();
    })
  }

  /** 译文朗读按钮 */
  @Builder
  speakOutButton() {
    Row({ space: 6 }) {
      SymbolGlyph(this.speakOutState === 'paused' ? $r('sys.symbol.play_fill')
        : $r('sys.symbol.speaker_wave_2'))
        .fontSize(15)
        .fontColor(this.speakOutState !== ''
          ? [$r('sys.color.ohos_id_color_text_primary_contrary')]
          : (this.ttsSupported(this.toLang)
            ? [$r('app.color.font_secondary')] : [$r('app.color.font_fourth')]))
      Text(this.speakOutState === 'playing' ? '暂停'
        : (this.speakOutState === 'paused' ? '继续'
          : (this.ttsSupported(this.toLang) ? '朗读' : '不支持')))
        .fontSize(12)
        .fontColor(this.speakOutState !== ''
          ? $r('sys.color.ohos_id_color_text_primary_contrary')
          : (this.ttsSupported(this.toLang)
            ? $r('app.color.font_secondary') : $r('app.color.font_fourth')))
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(40)
    .borderRadius(12)
    .backgroundColor(this.speakOutState !== '' ? $r('app.color.brand') : $r('app.color.card_bg'))
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.speakResult();
    })
  }
}
