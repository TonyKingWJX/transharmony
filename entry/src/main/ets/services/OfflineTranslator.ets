import { Context } from '@kit.AbilityKit';
import {
  AUTO_DETECT,
  LangCode,
  TranslationRequest,
  TranslationResult,
  TranslateError
} from '../models/TranslationTypes';

/**
 * 离线翻译内核（占位实现，无网络依赖）。
 * 翻译本体规划接入有道智云离线翻译 SDK（harmony_offline_nmt，HarmonyOS 版，
 * 支持中英/中日/中韩互译）；接入时仅需实现 infer()（调用 SDK 的翻译接口），
 * 方向解析/语言对校验等外围逻辑已就绪，UI 与引擎接入层不变。
 * 接入前对离线引擎发起的翻译会返回明确错误（2601），不影响其他引擎。
 */

/** 离线引擎 id（引擎行/聚合/历史里的 engineId） */
export const OFFLINE_ENGINE_ID = 'offline';

/**
 * 离线翻译功能总闸：翻译引擎接入前隐藏全部入口（服务页卡片/添加面板分区/引擎 chips）。
 * 引擎（有道智云离线 SDK 或开源方案）接入后改为 true 即整体恢复，UI 与数据层均保留。
 */
export const OFFLINE_FEATURE_ENABLED = false;

/** 已下载语言包（本期仅内置中英包；未来可下载包在此扩展） */
export interface OfflinePack {
  id: string;
  label: string;
  /** 覆盖的语言对描述（管理页展示） */
  pair: string;
  /** 是否随应用内置（内置包不可删除） */
  builtin: boolean;
}

/** 内置中英双向语言包 */
export const OFFLINE_PACK_ZH_EN: OfflinePack = {
  id: 'zh-en',
  label: '中英离线包',
  pair: '中 ⇄ 英',
  builtin: true
};

/** 方向解析结果（ArkTS 禁止内联对象类型，显式声明接口） */
interface DirectionResolution {
  /** 'zh2en' | 'en2zh'；空串 = 源语与目标相同（直接回显） */
  dir: string;
  resolvedFrom: LangCode;
}

export class OfflineTranslator {
  private static appCtx: Context | null = null;

  /** bootstrap 时注入应用上下文（rawfile 读取需要 resourceManager） */
  static init(context: Context): void {
    OfflineTranslator.appCtx = context;
  }

  static supportedLangs(): LangCode[] {
    return ['zh', 'en'];
  }

  /** 管理页展示的包体积（模型落地后由 prepare 脚本产物决定，此处为占位口径） */
  static packSizeLabel(): string {
    return '内置';
  }

  /**
   * 解析翻译方向。from=auto 时用 CJK 字符启发式判源语（离线无云端语种检测，
   * 而本引擎仅中英两个候选，字符面判断已足够稳）；目标语言必须为中/英。
   * 返回 resolvedFrom 供历史记录展示真实源语。
   */
  static resolveDirection(from: LangCode, to: LangCode, text: string): DirectionResolution {
    if (to !== 'zh' && to !== 'en') {
      throw new TranslateError(OFFLINE_ENGINE_ID, 2602, '离线翻译仅支持中英互译');
    }
    let src: LangCode;
    if (from === AUTO_DETECT) {
      src = OfflineTranslator.looksChinese(text) ? 'zh' : 'en';
    } else if (from === 'zh' || from === 'en') {
      src = from;
    } else {
      throw new TranslateError(OFFLINE_ENGINE_ID, 2602, '离线翻译仅支持中英互译');
    }
    if (src === to) {
      // 源语与目标相同（如英文原文译英文）：直接回显，与云端引擎行为一致
      return { dir: '', resolvedFrom: src };
    }
    return { dir: src === 'zh' ? 'zh2en' : 'en2zh', resolvedFrom: src };
  }

  /** 是否含中日韩统一表意文字（含扩展 A 区） */
  private static looksChinese(text: string): boolean {
    return /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/.test(text);
  }

  static async translate(req: TranslationRequest): Promise<TranslationResult> {
    const resolved = OfflineTranslator.resolveDirection(req.from, req.to, req.text);
    if (resolved.dir.length === 0) {
      const echo: TranslationResult = { text: req.text, providerId: OFFLINE_ENGINE_ID };
      echo.detectedFrom = resolved.resolvedFrom;
      return echo;
    }
    const out = await OfflineTranslator.infer(resolved.dir, req.text);
    const result: TranslationResult = { text: out, providerId: OFFLINE_ENGINE_ID };
    result.detectedFrom = resolved.resolvedFrom;
    return result;
  }

  /**
   * 翻译本体（待接入有道智云离线翻译 SDK）。
   * 接入前对离线引擎发起的翻译返回明确错误，聚合模式下表现为单卡失败，不影响其他引擎。
   */
  private static async infer(dir: string, text: string): Promise<string> {
    void dir;
    void text;
    throw new TranslateError(OFFLINE_ENGINE_ID, 2601, '离线翻译引擎尚未接入，敬请期待');
  }
}
