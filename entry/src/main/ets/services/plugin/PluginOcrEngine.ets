import pluginHost from 'libpluginhost.so';
import { bobPluginEngine, toBobLang } from './BobPluginEngine';

/**
 * 插件 OCR 执行层（文字识别服务插件）：
 * 调用插件 ocr(query, completion)，query 按 Bob 规范：
 *   imageB64（宿主 shim 转 $data.image）、from/detectFrom、pixelWidth/pixelHeight；
 * 结果解析 Bob ocr result 两种形态：texts（扁平行）或 regionInfos（段落结构），取文本行拼接。
 */
export class PluginOcrEngine {
  /** 识别：imageBase64 为图片（JPEG/PNG）base64，返回按行拼接的识别文本 */
  static async recognize(pluginId: string, imageBase64: string,
    fromLang: string, pixelWidth: number, pixelHeight: number): Promise<string> {
    await bobPluginEngine.ensureLoaded(pluginId);

    const bobFrom = toBobLang(fromLang === 'auto' ? 'auto' : fromLang);
    const query: Record<string, Object> = {
      'imageB64': imageBase64,
      'from': bobFrom,
      'detectFrom': bobFrom,
      'pixelWidth': pixelWidth,
      'pixelHeight': pixelHeight
    };

    const raw = await pluginHost.callPluginFn(pluginId, 'ocr',
      JSON.stringify([query]), 'callback', 60000);

    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(raw) as Record<string, Object>;
    } catch (e) {
      throw new Error('插件 OCR 返回无法解析');
    }
    if (parsed['error'] !== undefined && parsed['error'] !== null) {
      const err = parsed['error'] as Record<string, Object>;
      const msg = typeof err['message'] === 'string' ? err['message'] as string : '插件 OCR 错误';
      throw new Error(msg);
    }
    const result = parsed['result'] as Record<string, Object>;
    if (result === undefined || result === null) {
      throw new Error('插件未返回 OCR 结果');
    }

    const lines: string[] = [];
    const rawTexts = result['texts'];
    if (Array.isArray(rawTexts)) {
      for (const t of rawTexts as Array<Object>) {
        const to = t as Record<string, Object>;
        const text = typeof to['text'] === 'string' ? to['text'] as string : '';
        if (text.length > 0) {
          lines.push(text);
        }
      }
    } else {
      const rawRegions = result['regionInfos'];
      if (Array.isArray(rawRegions)) {
        for (const region of rawRegions as Array<Object>) {
          const ro = region as Record<string, Object>;
          const paras = ro['paragraphInfos'];
          if (!Array.isArray(paras)) {
            continue;
          }
          for (const para of paras as Array<Object>) {
            const po = para as Record<string, Object>;
            const texts = po['texts'];
            if (!Array.isArray(texts)) {
              continue;
            }
            let line = '';
            for (const t of texts as Array<Object>) {
              const to = t as Record<string, Object>;
              if (typeof to['text'] === 'string') {
                line += to['text'] as string;
              }
            }
            if (line.length > 0) {
              lines.push(line);
            }
          }
        }
      }
    }
    if (lines.length === 0) {
      throw new Error('插件未识别到文字');
    }
    return lines.join('\n');
  }
}
