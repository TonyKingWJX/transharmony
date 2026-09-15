/**
 * 服务商配置页（NavDestination；serviceId 由路由参数注入）：
 * - 头部：服务商徽标 + 名称/类型标签 + 启用开关（与列表页一致的启用/停用）
 * - 配置方法说明卡（配额/协议/注意事项）
 * - 凭证字段表单：由 ProviderCatalog.ProviderDef.fields 驱动；
 *   每个字段下方小字说明，带超链接的点击拉起浏览器直达控制台（获取密钥等）
 * - AI 服务商额外可改 API 地址（OpenAI/Anthropic 兼容默认留空）与模型名
 * - 保存即注入引擎，无需重启
 */

import { common, Want } from '@kit.AbilityKit';
import { settingsStore, ServiceItem } from '../services/SettingsStore';
import { TranslateUseCase } from '../services/TranslateUseCase';
import { findDef, ProviderDef, ConfigField } from '../services/ProviderCatalog';
import { defaultPromptText } from '../services/OpenAICompatAdapter';
import { fetchOpenAiModels, fetchAnthropicModels, fetchVisionModels, ModelListResult } from '../utils/AiModelApi';
import { OcrEngine } from '../services/OcrEngine';
import { TtsEngine } from '../services/TtsEngine';
import { PILL_VERSION_KEY } from '../components/EngineSelector';

@Component
export struct ServiceConfigPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  /** 路由参数：服务实例 id（Index.PageMap 注入） */
  @Prop serviceId: string = '';
  /** 路由参数：所属列表 'translate'（默认）| 'ocr' | 'tts'，区分读写哪个存储 */
  @Prop list: string = 'translate';
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @State service: ServiceItem | null = null;
  @State def: ProviderDef | null = null;
  /** 表单值（字段key → 输入值），与 config 分离，保存时整体写回 */
  @State values: Record<string, string> = {};
  @State svcEnabled: boolean = true;
  @State name: string = '';
  /** 连通测试：进行中/结果文案 */
  @State testing: boolean = false;
  @State testResult: string = '';
  @State testOk: boolean = false;
  /** AI：自动获取的模型列表 + 拉取中状态 */
  @State models: string[] = [];
  @State fetchingModels: boolean = false;
  /** TTS：目录预置音色清单（音色 Select 选项来源；即取即用，无需获取） */
  @State voices: string[] = [];

  aboutToAppear(): void {
    const s = settingsStore.getServiceIn(this.list, this.serviceId);
    if (s === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '未找到该服务' });
      this.pathStack.pop();
      return;
    }
    this.service = s;
    this.def = findDef(s.defId) ?? null;
    // TTS 预置音色清单（目录声明即取即用）
    this.voices = this.def !== null && this.def.ttsVoices !== undefined ? this.def.ttsVoices : [];
    // 载入已存配置
    const values: Record<string, string> = {};
    for (const k of Object.keys(s.config)) {
      values[k] = s.config[k];
    }
    this.values = values;
    this.svcEnabled = s.enabled;
    this.name = s.name;
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 拉起浏览器打开链接（deep-linking 官方隐式 Want 方式） */
  private openLink(url: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      context.startAbility(want);
    } catch (e) {
      this.toast('无法打开链接：' + url);
    }
  }

  private async save(): Promise<void> {
    if (this.service === null || this.def === null) {
      return;
    }
    const sid = this.service.id;
    // 必填校验
    for (const f of this.def.fields) {
      if (!f.optional && (this.values[f.key] ?? '').trim().length === 0) {
        this.toast('请填写「' + f.label + '」');
        return;
      }
    }
    const list = settingsStore.getServiceList(this.list);
    const hit = list.find((s: ServiceItem): boolean => s.id === sid);
    if (hit !== undefined) {
      hit.config = this.values;
      hit.enabled = this.svcEnabled;
      hit.name = this.name.trim().length > 0 ? this.name.trim() : this.def.label;
    }
    await settingsStore.setServiceList(this.list, list);
    // 翻译列表变更需重建引擎；OCR/TTS 列表与翻译引擎无关，只广播偏好选择刷新
    if (this.list === 'translate') {
      TranslateUseCase.refreshServices();
    }
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.toast('已保存');
    this.pathStack.pop();
  }

  /** 删除（AlertDialog 二次确认） */
  private confirmDelete(): void {
    if (this.service === null) {
      return;
    }
    const name = this.name.trim().length > 0 ? this.name.trim() : this.service.name;
    this.getUIContext().showAlertDialog({
      title: '删除服务商',
      message: '确定删除「' + name + '」？删除后其凭证配置将一并清除。',
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        style: DialogButtonStyle.HIGHLIGHT,
        action: (): void => {
          this.remove();
        }
      },
      cancel: (): void => {
      }
    });
  }

  private async remove(): Promise<void> {
    if (this.service === null) {
      return;
    }
    const sid = this.service.id;
    await settingsStore.setServiceList(
      this.list,
      settingsStore.getServiceList(this.list).filter((s: ServiceItem): boolean => s.id !== sid));
    if (this.list === 'translate') {
      TranslateUseCase.refreshServices();
    }
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
    this.toast('已删除该服务商');
    this.pathStack.pop();
  }

  private async toggle(on: boolean): Promise<void> {
    this.svcEnabled = on;
    if (this.service === null) {
      return;
    }
    const sid = this.service.id;
    const list = settingsStore.getServiceList(this.list);
    const hit = list.find((s: ServiceItem): boolean => s.id === sid);
    if (hit !== undefined) {
      hit.enabled = on;
      await settingsStore.setServiceList(this.list, list);
    }
    if (this.list === 'translate') {
      TranslateUseCase.refreshServices();
    }
    AppStorage.setOrCreate(PILL_VERSION_KEY, Date.now());
  }

  /** 连通测试：用当前表单值即时生效（不必先保存）；OCR/TTS 走各自执行器，翻译走翻译管线 */
  private async runTest(): Promise<void> {
    if (this.service === null || this.testing) {
      return;
    }
    const sid = this.service.id;
    // 表单值即时写回（不落盘保存与否由用户决定；写入即生效供测试用）
    const list = settingsStore.getServiceList(this.list);
    const hit = list.find((s: ServiceItem): boolean => s.id === sid);
    if (hit !== undefined) {
      hit.config = this.values;
      await settingsStore.setServiceList(this.list, list);
      if (this.list === 'translate') {
        TranslateUseCase.refreshServices();
      }
    }
    this.testing = true;
    this.testResult = '';
    if (this.list === 'ocr') {
      const r = await OcrEngine.testService(sid);
      this.testOk = r.ok;
      this.testResult = r.message;
    } else if (this.list === 'tts') {
      const r = await TtsEngine.testService(sid);
      this.testOk = r.ok;
      this.testResult = r.message;
    } else {
      const r = await TranslateUseCase.testService(sid);
      this.testOk = r.ok;
      this.testResult = r.message;
    }
    this.testing = false;
  }

  /** AI：自动获取模型列表（OCR AI 实例过滤为视觉模型，过滤为空时回退全量） */
  private async fetchModels(): Promise<void> {
    if (this.def === null || this.fetchingModels) {
      return;
    }
    this.fetchingModels = true;
    const base = (this.values['baseUrl'] ?? '').length > 0
      ? this.values['baseUrl'] : this.def.baseUrl;
    const apiKey = this.values['apiKey'] ?? '';
    let r: ModelListResult;
    if (this.def.kind === 'ocr-ai') {
      // OCR AI：只要标注「视觉」的模型；白名单无命中时 fetchVisionModels 返回全量（宽松策略）
      r = await fetchVisionModels(base, apiKey, this.def.aiFormat);
    } else {
      r = this.def.aiFormat === 'anthropic'
        ? await fetchAnthropicModels(base, apiKey)
        : await fetchOpenAiModels(base, apiKey);
    }
    this.fetchingModels = false;
    if (r.error.length > 0) {
      this.toast('获取模型失败：' + r.error);
      return;
    }
    this.models = r.models;
    // 当前手填的模型不在列表中时追加，避免 Select 覆盖用户输入
    const cur = this.values['model'] ?? '';
    if (cur.length > 0 && !r.models.includes(cur)) {
      this.models = [cur, ...r.models];
    }
    if (r.models.length > 0) {
      this.toast('已获取 ' + r.models.length + ' 个模型');
    }
  }

  /** Select 选项：自动获取到的模型列表（ArkTS 对象字面量须对应显式接口） */
  private modelOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const m of this.models) {
      const o: SelectOption = { value: m };
      opts.push(o);
    }
    return opts;
  }

  /** Select 显示文本：未获取时给操作引导，已获取显示当前模型名 */
  private selectValue(): string {
    if (this.models.length === 0) {
      return '填写密钥后点击「自动获取」';
    }
    const cur = this.values['model'] ?? '';
    return cur.length > 0 ? cur : '点击选择模型';
  }

  /** Select 字色：有可选模型且已有选中值时用主色，其余用弱化色（占位观感） */
  private selectFontColor(): ResourceColor {
    if (this.models.length === 0) {
      return $r('app.color.font_tertiary');
    }
    const cur = this.values['model'] ?? '';
    return cur.length > 0 ? $r('app.color.font_primary') : $r('app.color.font_tertiary');
  }

  /** TTS 音色 Select 选项：目录预置清单（ArkTS 对象字面量须对应显式接口） */
  private voiceOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (const v of this.voices) {
      const o: SelectOption = { value: v };
      opts.push(o);
    }
    return opts;
  }

  /** TTS 音色 Select 显示文本：无预置清单引导手填，已有选中值显示当前音色 */
  private voiceValue(): string {
    if (this.voices.length === 0) {
      return '该服务未公开音色列表，请手填';
    }
    const cur = this.values['voice'] ?? '';
    return cur.length > 0 ? cur : '点击选择音色';
  }

  /** TTS 音色 Select 字色：有选中值时用主色，其余弱化（占位观感） */
  private voiceFontColor(): ResourceColor {
    if (this.voices.length === 0) {
      return $r('app.color.font_tertiary');
    }
    const cur = this.values['voice'] ?? '';
    return cur.length > 0 ? $r('app.color.font_primary') : $r('app.color.font_tertiary');
  }

  /** TTS 音色手填占位：目录有默认音色时提示默认值 */
  private voicePlaceholder(): string {
    if (this.def !== null && this.def.defaultVoice !== undefined && this.def.defaultVoice.length > 0) {
      return '默认：' + this.def.defaultVoice;
    }
    return '音色名（留空使用服务端默认）';
  }

  /** 头部显示名：用户改名实时跟随 */
  private displayName(): string {
    const fallback = this.def !== null ? this.def.label : '服务配置';
    return this.name.trim().length > 0 ? this.name.trim() : fallback;
  }

  /** 头部类型标签：按列表/类型区分（机器翻译 / AI 大模型 / 传统 OCR / AI 视觉 / 语音合成） */
  private typeLabel(): string {
    if (this.def === null) {
      return '';
    }
    if (this.list === 'ocr') {
      return this.def.kind === 'ocr-trad' ? '传统 OCR' : 'AI 视觉';
    }
    if (this.list === 'tts') {
      return '语音合成';
    }
    return this.def.isAI ? 'AI 大模型' : '机器翻译';
  }

  /** 连通测试小字说明：按列表区分（翻译试译 / OCR 实测识别 / TTS 试合成） */
  private testHint(): string {
    if (this.list === 'ocr') {
      return '用当前填写的凭证实测一次文字识别（内置纯色测试图，无文字属预期），无需先保存';
    }
    if (this.list === 'tts') {
      return '用当前填写的凭证合成一句测试语音（不播放），无需先保存';
    }
    return '用当前填写的凭证试译「你好，世界。」→ English，无需先保存';
  }

  build() {
    NavDestination() {
      Column() {
        Blank().height(this.statusBarH)

        // 自定义标题栏（全屏窗口下 hideTitleBar + 手动避让状态栏）
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

          Text(this.displayName())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 14 }) {
            // ── 头部卡：徽标 + 名称/类型 + 启用开关 ──
            Row({ space: 12 }) {
              Text(this.def !== null ? this.def.badge : '')
                .fontSize(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .width(44)
                .height(44)
                .textAlign(TextAlign.Center)
                .borderRadius(12)
                .backgroundColor(this.def !== null ? this.def.color : '#0A9BFF')
              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  Text(this.displayName())
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.def !== null) {
                    Text(this.typeLabel())
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.brand'))
                      .backgroundColor($r('app.color.emphasize_bg_light'))
                      .borderRadius(999)
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                  }
                }
                .alignItems(VerticalAlign.Center)

                Text('关闭后不参与聚合并发与引擎选择')
                  .fontSize(12)
                  .fontColor($r('app.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.svcEnabled })
                .width(44)
                .height(24)
                .selectedColor($r('app.color.brand'))
                .onChange((on: boolean) => {
                  this.toggle(on);
                })
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(VerticalAlign.Center)

            // ── 连通测试卡（所有服务商可用；填好凭证即可测，无需先保存） ──
            Column({ space: 10 }) {
              Text('连通测试')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')

              Column({ space: 10 }) {
                Button() {
                  Row({ space: 8 }) {
                    if (this.testing) {
                      LoadingProgress().width(16).height(16).color($r('sys.color.ohos_id_color_text_primary_contrary'))
                    }
                    Text(this.testing ? '测试中' : '测试连通')
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                  }
                  .alignItems(VerticalAlign.Center)
                }
                  .width('100%')
                  .height(42)
                  .borderRadius(21)
                  .backgroundColor($r('app.color.brand'))
                  .enabled(!this.testing)
                  .onClick(() => {
                    this.runTest();
                  })
                if (this.testResult.length > 0) {
                  Row({ space: 5 }) {
                    SymbolGlyph(this.testOk ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.exclamationmark_circle'))
                      .fontSize(14)
                      .fontColor([this.testOk ? $r('app.color.confirm') : $r('app.color.warning')])
                    Text(this.testResult)
                      .fontSize(12)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(this.testOk ? $r('app.color.font_secondary') : $r('app.color.warning'))
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 4, right: 4 })
                  .alignItems(VerticalAlign.Center)
                }
              }
              .width('100%')

              Text(this.testHint())
                .fontSize(11)
                .fontColor($r('app.color.font_fourth'))
                .width('100%')
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── 说明卡（配置方法 + 小字引导） ──
            Column({ space: 8 }) {
              Text('配置方法')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
              Text(this.def !== null ? this.def.note : '')
                .fontSize(12)
                .lineHeight(20)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')

              // 免责声明：费用与账号归属第三方服务商
              Text('免责声明：各服务由对应服务商官方提供，请使用本人账号开通；用量与费用以服务商计费规则为准，与本应用无关。')
                .fontSize(11)
                .lineHeight(17)
                .fontColor($r('app.color.font_fourth'))
                .width('100%')
                .padding({ top: 2 })

              // AI 生成内容提示（合规）：仅 AI 服务展示，另起一行跟在免责声明后
              if (this.def !== null && this.def.isAI) {
                Row({ space: 5 }) {
                  SymbolGlyph($r('sys.symbol.AI'))
                    .fontSize(12)
                    .fontColor([$r('app.color.brand')])
                  Text('内容由AI生成，请仔细甄别')
                    .fontSize(12)
                    .fontColor($r('app.color.brand'))
                }
                .width('100%')
                .padding({ top: 2 })
                .alignItems(VerticalAlign.Center)
              }
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── 名称卡（可改显示名） ──
            Column({ space: 8 }) {
              Text('显示名称')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
              TextInput({ placeholder: this.def !== null ? this.def.label : '', text: this.name })
                .fontSize(14)
                .height(46)
                .width('100%')
                .borderRadius(12)
                .backgroundColor($r('app.color.bg_container'))
                .padding({ left: 12, right: 12 })
                .onChange((v: string): void => {
                  this.name = v;
                })
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── 凭证字段卡（含超链接小字） ──
            if (this.def !== null && this.def.fields.length > 0) {
              Column({ space: 14 }) {
                Text('凭证配置')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_secondary'))
                  .letterSpacing(1)
                  .width('100%')

                ForEach(this.def.fields, (f: ConfigField) => {
                  Column({ space: 6 }) {
                    Row({ space: 3 }) {
                      Text(f.label)
                        .fontSize(13)
                        .fontColor($r('app.color.font_secondary'))
                      if (!f.optional) {
                        Text('*')
                          .fontSize(13)
                          .fontColor($r('app.color.warning'))
                      }
                    }
                    .width('100%')

                    TextInput({ placeholder: f.placeholder, text: this.values[f.key] ?? '' })
                      .type(f.secret ? InputType.Password : InputType.Normal)
                      .fontSize(14)
                      .height(46)
                      .width('100%')
                      .borderRadius(12)
                      .backgroundColor($r('app.color.bg_container'))
                      .padding({ left: 12, right: 12 })
                      .onChange((v: string): void => {
                        this.values[f.key] = v;
                      })

                    // 小字说明：说明文字与链接各占一行，避免混排换行错乱
                    if (f.hint.length > 0) {
                      Text(f.hint)
                        .fontSize(12)
                        .lineHeight(18)
                        .fontColor($r('app.color.font_tertiary'))
                        .width('100%')
                      if (f.link.length > 0) {
                        Row({ space: 3 }) {
                          Text(f.linkText)
                            .fontSize(12)
                            .fontWeight(FontWeight.Medium)
                            .fontColor($r('app.color.brand'))
                          SymbolGlyph($r('sys.symbol.chevron_right'))
                            .fontSize(11)
                            .fontColor([$r('app.color.brand')])
                        }
                        .margin({ top: 2 })
                        .alignItems(VerticalAlign.Center)
                        .onClick(() => {
                          this.openLink(f.link);
                        })
                      }
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }, (f: ConfigField) => f.key)
              }
              .width('100%')
              .padding(14)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .alignItems(HorizontalAlign.Start)
            }

            // ── AI：API 地址 + 模型名 ──
            if (this.def !== null && this.def.isAI) {
              Column({ space: 14 }) {
                Text('模型设置')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.font_secondary'))
                  .letterSpacing(1)
                  .width('100%')

                Column({ space: 6 }) {
                  Text('API 地址' + (this.def.baseUrl.length > 0 ? '' : ' *'))
                    .fontSize(13)
                    .fontColor($r('app.color.font_secondary'))
                    .width('100%')
                  TextInput({
                    placeholder: this.def.baseUrl.length > 0
                      ? '默认：' + this.def.baseUrl
                      : 'https://api.example.com/v1',
                    text: this.values['baseUrl'] ?? ''
                  })
                    .fontSize(14)
                    .height(46)
                    .width('100%')
                    .borderRadius(12)
                    .backgroundColor($r('app.color.bg_container'))
                    .padding({ left: 12, right: 12 })
                    .onChange((v: string): void => {
                      this.values['baseUrl'] = v;
                    })
                  Text(this.def.aiFormat === 'anthropic'
                    ? (this.list === 'tts'
                      ? '填到域名根（应用自动拼接 /v1/audio/speech），留空使用默认地址'
                      : '填到域名根（不带 /v1/messages），留空使用默认地址')
                    : 'OpenAI 兼容：填到 /v1 这一级，留空使用默认地址')
                    .fontSize(12)
                    .lineHeight(18)
                    .fontColor($r('app.color.font_tertiary'))
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)

                Column({ space: 6 }) {
                  Row() {
                    Text('模型名')
                      .fontSize(13)
                      .fontColor($r('app.color.font_secondary'))
                    Blank()
                    if (this.fetchingModels) {
                      LoadingProgress()
                        .width(16)
                        .height(16)
                        .color($r('app.color.brand'))
                    } else {
                      Text('自动获取')
                        .fontSize(12)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.brand'))
                        .padding({ left: 8, right: 2, top: 4, bottom: 4 })
                        .onClick(() => {
                          this.fetchModels();
                        })
                    }
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)

                  // 常驻下拉选择：自动获取成功后列出可选模型（Select 菜单选项超屏自动滚动，
                  // 几十上百项都能兜住，不会像平铺列表那样溢出盖住下方表单）；
                  // 未获取前置灰并引导先自动获取。手动输入框保留，两者写同一个 model 值
                  Select(this.modelOptions())
                    .selected(this.models.indexOf(this.values['model'] ?? ''))
                    .value(this.selectValue())
                    .enabled(this.models.length > 0)
                    .font({ size: 14 })
                    .fontColor(this.selectFontColor())
                    .optionFont({ size: 13 })
                    .height(46)
                    .width('100%')
                    .borderRadius(12)
                    .backgroundColor($r('app.color.bg_container'))
                    .padding({ left: 12, right: 12 })
                    .onSelect((index: number, text: string) => {
                      if (index >= 0 && index < this.models.length) {
                        this.values['model'] = this.models[index];
                      }
                    })
                  TextInput({
                    placeholder: this.def.defaultModel.length > 0
                      ? '默认：' + this.def.defaultModel : '模型名',
                    text: this.values['model'] ?? ''
                  })
                  .fontSize(14)
                  .height(46)
                  .width('100%')
                  .borderRadius(12)
                  .backgroundColor($r('app.color.bg_container'))
                  .padding({ left: 12, right: 12 })
                  .onChange((v: string): void => {
                    this.values['model'] = v;
                  })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)

                // ── TTS：音色（预置清单即取即用 + 自定义手填，两者写同一 voice 值） ──
                if (this.def.kind === 'tts-ai') {
                  Column({ space: 6 }) {
                    Text('音色（voice）')
                      .fontSize(13)
                      .fontColor($r('app.color.font_secondary'))
                      .width('100%')

                    // 预置音色下拉（目录声明即取即用，无需获取）；无预置的服务置灰引导手填
                    Select(this.voiceOptions())
                      .selected(this.voices.indexOf(this.values['voice'] ?? ''))
                      .value(this.voiceValue())
                      .enabled(this.voices.length > 0)
                      .font({ size: 14 })
                      .fontColor(this.voiceFontColor())
                      .optionFont({ size: 13 })
                      .height(46)
                      .width('100%')
                      .borderRadius(12)
                      .backgroundColor($r('app.color.bg_container'))
                      .padding({ left: 12, right: 12 })
                      .onSelect((index: number, text: string) => {
                        if (index >= 0 && index < this.voices.length) {
                          this.values['voice'] = this.voices[index];
                        }
                      })
                    TextInput({ placeholder: this.voicePlaceholder(), text: this.values['voice'] ?? '' })
                      .fontSize(14)
                      .height(46)
                      .width('100%')
                      .borderRadius(12)
                      .backgroundColor($r('app.color.bg_container'))
                      .padding({ left: 12, right: 12 })
                      .onChange((v: string): void => {
                        this.values['voice'] = v;
                      })
                    Text('预置音色即选即用；自定义音色以服务商文档为准，留空使用默认音色。')
                      .fontSize(11)
                      .lineHeight(16)
                      .fontColor($r('app.color.font_fourth'))
                      .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }

                // ── 自定义翻译 Prompt（仅翻译 AI 实例；OCR/TTS 实例不展示） ──
                if (this.def.kind === 'ai') {
                  Column({ space: 6 }) {
                    Text('翻译 Prompt（可选）')
                      .fontSize(13)
                      .fontColor($r('app.color.font_secondary'))
                      .width('100%')
                    TextArea({ placeholder: defaultPromptText(), text: this.values['prompt'] ?? '' })
                      .fontSize(13)
                      .height(120)
                      .width('100%')
                      .borderRadius(12)
                      .backgroundColor($r('app.color.bg_container'))
                      .padding(10)
                      .onChange((v: string): void => {
                        this.values['prompt'] = v;
                      })
                    Text('留空使用内置 Prompt。可用 {target_language} 占位目标语言；未写则自动追加到末尾。')
                      .fontSize(11)
                      .lineHeight(16)
                      .fontColor($r('app.color.font_fourth'))
                      .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                }
              }
              .width('100%')
              .padding(14)
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
              .alignItems(HorizontalAlign.Start)
            }

            Button('保存并生效')
              .width('100%')
              .height(44)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .borderRadius(22)
              .backgroundColor($r('app.color.brand'))
              .margin({ top: 4 })
              .onClick(() => {
                this.save();
              })

            Button('删除该服务商')
              .width('100%')
              .height(44)
              .fontSize(15)
              .fontColor($r('app.color.warning'))
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: $r('app.color.warning') })
              .borderRadius(22)
              .onClick(() => {
                this.confirmDelete();
              })

            Text('凭证仅保存在本机，翻译请求直连对应服务商')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 2 })
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
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
