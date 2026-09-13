import pluginHost from 'libpluginhost.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TranslatorAdapter } from '../TranslatorAdapter';
import {
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../../models/TranslationTypes';
import { bobPluginEngine } from './BobPluginEngine';
import {
  manggoEntryGlobalName,
  splitServiceRef,
  toManggoLang,
  applyManggoLangMap,
  manggoServiceLangs
} from './ManggoTypes';

/**
 * manggo 翻译插件适配器（kind=translation）：把 manggo 多服务插件的翻译服务
 * 包装成应用统一的 TranslatorAdapter。调用约定（manggo.plugin.v1）：
 *  - 入口 async translate(text, from, to, options)，经 promise 模式调用（global '__phSvc_<serviceId>'）；
 *  - from/to 传 manggo 码并按清单 language 映射为第三方码；第 4 参 = options.detect；
 *  - 普通文本返回字符串；词典服务（resultType=dictionary）返回 {kind:'dictionary', dictionary:{...}}；
 *  - 流式：options.setResult(chunk) 逐段发增量 → {__manggoDelta} 信封 → 流监听累积回传。
 */

export class ManggoPluginAdapter implements TranslatorAdapter {
  readonly pluginId: string;
  readonly serviceId: string;
  /** 清单声明结果形态：'text' | 'dictionary' */
  readonly resultType: string;
  /** 清单 language 映射原文 JSON（manggo 码 → 第三方码） */
  readonly languageJson: string;
  id: string;
  label: string;
  isAI: boolean = false;
  supportsStyle: boolean = false;
  needsConfig: boolean = true;

  /** 插件超时（毫秒） */
  private static readonly TIMEOUT_MS: number = 30000;
  /** 错误码段：插件类（2900/2901 已被 Bob 适配器占用） */
  private static readonly ERR_PLUGIN = 2902;
  private static readonly ERR_HOST = 2903;

  constructor(serviceItemId: string, pluginId: string, serviceId: string, label: string,
    resultType: string, languageJson: string) {
    this.id = serviceItemId;
    this.pluginId = pluginId;
    this.serviceId = serviceId;
    this.label = label;
    this.resultType = resultType;
    this.languageJson = languageJson;
  }

  /** 从 ServiceItem.id/defId 构造（ref = 'plugin:<pid>#<sid>' 或裸 '<pid>#<sid>'） */
  static fromRef(serviceItemId: string, ref: string, label: string): ManggoPluginAdapter {
    const parts = splitServiceRef(ref);
    return new ManggoPluginAdapter(serviceItemId, parts.pluginId, parts.serviceId, label, 'text', '');
  }

  private fnName(): string {
    return manggoEntryGlobalName(this.serviceId);
  }

  async translate(req: TranslationRequest): Promise<TranslationResult> {
    hilog.info(0x0001, 'ManggoPluginAdapter',
      'translate enter plugin=%{public}s svc=%{public}s %{public}s->%{public}s',
      this.pluginId, this.serviceId, req.from, req.to);
    try {
      await bobPluginEngine.ensureLoaded(this.pluginId);
    } catch (e) {
      const loadMsg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0001, 'ManggoPluginAdapter', 'ensureLoaded failed: %{public}s', loadMsg);
      throw new TranslateError(this.id, ManggoPluginAdapter.ERR_HOST, '插件加载失败: ' + loadMsg);
    }

    const fromMg = toManggoLang(req.from);
    const toMg = toManggoLang(req.to);
    // from/to 按清单 language 映射为第三方码；detect 由应用书写系统嗅探（manggo 码）后同样映射
    const fromArg = applyManggoLangMap(this.languageJson, fromMg);
    const toArg = applyManggoLangMap(this.languageJson, toMg);
    const detectMg = req.from !== 'auto' ? fromMg
      : toManggoLang(ManggoPluginAdapter.sniffLang(req.text));
    const detectArg = applyManggoLangMap(this.languageJson, detectMg);

    let raw: string;
    try {
      raw = await pluginHost.callPluginFn(this.pluginId, this.fnName(),
        JSON.stringify([req.text, fromArg, toArg, detectArg]),
        'promise', ManggoPluginAdapter.TIMEOUT_MS);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      hilog.error(0x0001, 'ManggoPluginAdapter', 'callPluginFn failed: %{public}s', msg);
      throw new TranslateError(this.id, ManggoPluginAdapter.ERR_PLUGIN, msg);
    }

    let parsed: Object;
    try {
      parsed = JSON.parse(raw) as Object;
    } catch (e) {
      throw new TranslateError(this.id, ManggoPluginAdapter.ERR_HOST, '插件返回了无法解析的结果');
    }
    if (parsed === null || parsed === undefined) {
      throw new TranslateError(this.id, ManggoPluginAdapter.ERR_PLUGIN, '插件未返回结果');
    }

    let text = '';
    if (typeof parsed === 'string') {
      text = parsed as string;
    } else if (Array.isArray(parsed)) {
      // 宽容处理：分段字符串数组
      const parts: string[] = [];
      for (const p of parsed as Array<Object>) {
        if (typeof p === 'string') {
          parts.push(p as string);
        }
      }
      text = parts.join('\n');
    } else {
      const obj = parsed as Record<string, Object>;
      // 词典结果（resultType=dictionary 的结构化返回）
      const dictRaw = obj['dictionary'];
      if (obj['kind'] === 'dictionary' && dictRaw !== undefined && dictRaw !== null
        && typeof dictRaw === 'object') {
        text = ManggoPluginAdapter.flattenDictionary(dictRaw as Record<string, Object>);
      } else if (typeof obj['text'] === 'string') {
        // 宽容处理：作者误包一层 {text}
        text = obj['text'] as string;
      }
    }
    text = text.trim();
    if (text.length === 0) {
      throw new TranslateError(this.id, ManggoPluginAdapter.ERR_PLUGIN, '插件未返回结果');
    }

    const out: TranslationResult = {
      text: text,
      providerId: this.id,
      detectedFrom: req.from === 'auto' ? ManggoPluginAdapter.sniffLang(req.text) : undefined
    };
    return out;
  }

  supportedLangs(): LangCode[] {
    const declared = manggoServiceLangs(this.languageJson);
    if (declared.length === 0) {
      return bobPluginEngine.langsOf(this.pluginId);
    }
    return declared;
  }

  /** 流式翻译：options.setResult 增量（{__manggoSvc, __manggoDelta}）累积为完整文本回传。
   *  同插件多服务并发流式时按 __manggoSvc 过滤，只收本服务的增量，互不串流。 */
  async translateStream(req: TranslationRequest,
    onDelta: (fullText: string) => void): Promise<TranslationResult> {
    let acc = '';
    const listener = (resultJson: string): void => {
      try {
        const parsed = JSON.parse(resultJson) as Record<string, Object>;
        const svc = parsed['__manggoSvc'];
        if (typeof svc === 'string' && (svc as string) !== this.serviceId) {
          return; // 同插件其他服务的增量
        }
        const delta = parsed['__manggoDelta'];
        if (typeof delta === 'string' && (delta as string).length > 0) {
          acc += delta as string;
          onDelta(acc);
        }
      } catch (e) {
        // 流式增量解析失败忽略，等最终结果
      }
    };
    bobPluginEngine.setStreamListener(this.pluginId, listener);
    try {
      return await this.translate(req);
    } finally {
      bobPluginEngine.clearStreamListener(this.pluginId, listener);
    }
  }

  /** 书写系统嗅探（内部码）：日文假名/韩文谚文/汉字/西里尔 → 对应语言，其余按拉丁 */
  private static sniffLang(text: string): LangCode {
    if (/[\u3040-\u30ff]/.test(text)) {
      return 'ja';
    }
    if (/[\uac00-\ud7af]/.test(text)) {
      return 'ko';
    }
    if (/[\u4e00-\u9fff]/.test(text)) {
      return 'zh';
    }
    if (/[\u0400-\u04ff]/.test(text)) {
      return 'ru';
    }
    return 'en';
  }

  /** manggo 词典结构 → 可读文本（词头/发音/词性释义/例证/变形/属性） */
  private static flattenDictionary(dict: Record<string, Object>): string {
    const lines: string[] = [];
    const word = dict['word'];
    if (typeof word === 'string' && (word as string).length > 0) {
      const lang = typeof dict['language'] === 'string' ? ` (${dict['language'] as string})` : '';
      lines.push((word as string) + lang);
    }
    const rawProns = dict['pronunciations'];
    if (Array.isArray(rawProns)) {
      const ph: string[] = [];
      for (const p of rawProns as Array<Object>) {
        if (typeof p !== 'object' || p === null) {
          continue;
        }
        const po = p as Record<string, Object>;
        const label = typeof po['label'] === 'string' ? po['label'] as string : '';
        const phonetic = typeof po['phonetic'] === 'string' ? po['phonetic'] as string : '';
        if (phonetic.length > 0) {
          ph.push((label.length > 0 ? label + ' ' : '') + phonetic);
        }
      }
      if (ph.length > 0) {
        lines.push(ph.join('   '));
      }
    }
    const rawMeanings = dict['meanings'];
    if (Array.isArray(rawMeanings)) {
      for (const m of rawMeanings as Array<Object>) {
        if (typeof m !== 'object' || m === null) {
          continue;
        }
        const mo = m as Record<string, Object>;
        const pos = typeof mo['partOfSpeech'] === 'string' ? mo['partOfSpeech'] as string : '';
        const defs: string[] = [];
        for (const key of ['translations', 'definitions', 'extendedDefinitions']) {
          const arr = mo[key];
          if (Array.isArray(arr)) {
            for (const d of arr as Array<Object>) {
              if (typeof d === 'string' && (d as string).length > 0) {
                defs.push(d as string);
              }
            }
          }
        }
        if (defs.length > 0) {
          lines.push((pos.length > 0 ? pos + ' ' : '') + defs.join('；'));
        }
        const rawExamples = mo['examples'];
        if (Array.isArray(rawExamples)) {
          for (const ex of rawExamples as Array<Object>) {
            const t = typeof ex === 'string' ? ex as string
              : (typeof ex === 'object' && ex !== null
                && typeof (ex as Record<string, Object>)['text'] === 'string')
                ? (ex as Record<string, Object>)['text'] as string : '';
            if (t.length > 0) {
              lines.push('  例 ' + t);
            }
          }
        }
        const syn = ManggoPluginAdapter.wordList(mo['synonyms']);
        if (syn.length > 0) {
          lines.push('  近义词：' + syn.join('、'));
        }
        const ant = ManggoPluginAdapter.wordList(mo['antonyms']);
        if (ant.length > 0) {
          lines.push('  反义词：' + ant.join('、'));
        }
      }
    }
    const rawForms = dict['forms'];
    if (Array.isArray(rawForms)) {
      const forms: string[] = [];
      for (const f of rawForms as Array<Object>) {
        if (typeof f !== 'object' || f === null) {
          continue;
        }
        const fo = f as Record<string, Object>;
        const t = typeof fo['type'] === 'string' ? fo['type'] as string : '';
        const w = typeof fo['word'] === 'string' ? fo['word'] as string : '';
        if (w.length > 0) {
          forms.push((t.length > 0 ? t + ':' : '') + w);
        }
      }
      if (forms.length > 0) {
        lines.push('变形：' + forms.join('、'));
      }
    }
    const rawProps = dict['properties'];
    if (Array.isArray(rawProps)) {
      for (const p of rawProps as Array<Object>) {
        if (typeof p !== 'object' || p === null) {
          continue;
        }
        const po = p as Record<string, Object>;
        const label = typeof po['label'] === 'string' ? po['label'] as string
          : (typeof po['key'] === 'string' ? po['key'] as string : '');
        const value = typeof po['value'] === 'string' ? po['value'] as string : '';
        if (label.length > 0 && value.length > 0) {
          lines.push(label + '：' + value);
        }
      }
    }
    if (lines.length === 0 && typeof word === 'string') {
      lines.push(word as string);
    }
    return lines.join('\n');
  }

  private static wordList(raw: Object): string[] {
    const out: string[] = [];
    if (Array.isArray(raw)) {
      for (const w of raw as Array<Object>) {
        if (typeof w === 'string' && (w as string).length > 0) {
          out.push(w as string);
        }
      }
    }
    return out;
  }
}
