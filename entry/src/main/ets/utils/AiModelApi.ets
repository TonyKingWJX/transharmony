import { getJson } from '../utils/HttpClient';
import { safeParse, getArr, getStr } from '../utils/JsonUtil';

/**
 * AI 模型列表拉取（配置页「自动获取模型」用）。
 * - OpenAI 兼容：GET {base}/models，响应 { data: [{ id: "..." }] }
 * - Anthropic：GET {base}/v1/models，响应 { data: [{ id: "..." }] }
 * 两家返回结构一致（data[].id），统一解析。
 */

export interface ModelListResult {
  /** 模型 id 列表（升序） */
  models: string[];
  /** 失败时的错误文案（成功为空串） */
  error: string;
}

export async function fetchOpenAiModels(baseUrl: string, apiKey: string): Promise<ModelListResult> {
  const base = trimSlash(baseUrl);
  if (base.length === 0) {
    return { models: [], error: '请先填写 API 地址' };
  }
  const headers: Record<string, string> = {
    'Content-Type': 'application/json'
  };
  if (apiKey.length > 0) {
    headers['Authorization'] = 'Bearer ' + apiKey;
  }
  try {
    const resp = await getJson({ url: base + '/models', headers: headers, body: '', timeoutMs: 15000 });
    const root = safeParse(resp.body);
    if (root === null) {
      return { models: [], error: '响应解析失败: ' + resp.body.substring(0, 120) };
    }
    const data = getArr(root, 'data');
    const out: string[] = [];
    for (const it of data) {
      const id = getStr(it, 'id');
      if (id.length > 0) {
        out.push(id);
      }
    }
    if (out.length === 0) {
      return { models: [], error: '模型列表为空' };
    }
    out.sort();
    return { models: out, error: '' };
  } catch (e) {
    return { models: [], error: e instanceof Error ? e.message : '网络请求失败' };
  }
}

export async function fetchAnthropicModels(baseUrl: string, apiKey: string): Promise<ModelListResult> {
  const base = trimSlash(baseUrl.length > 0 ? baseUrl : 'https://api.anthropic.com');
  try {
    const resp = await getJson({
      url: base + '/v1/models?limit=100',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: '',
      timeoutMs: 15000
    });
    const root = safeParse(resp.body);
    if (root === null) {
      return { models: [], error: '响应解析失败: ' + resp.body.substring(0, 120) };
    }
    const data = getArr(root, 'data');
    const out: string[] = [];
    for (const it of data) {
      const id = getStr(it, 'id');
      if (id.length > 0) {
        out.push(id);
      }
    }
    if (out.length === 0) {
      return { models: [], error: '模型列表为空' };
    }
    out.sort();
    return { models: out, error: '' };
  } catch (e) {
    return { models: [], error: e instanceof Error ? e.message : '网络请求失败' };
  }
}

function trimSlash(s: string): string {
  return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

/**
 * 视觉（多模态）模型名匹配：标准 OpenAI /models 响应不带视觉标注，这里按
 * 已知视觉模型系列的命名特征保守匹配（OCR「自动获取」用）。命中为空时调用方回退全量列表。
 */
const VISION_NAME_RE = /(vision|-vl|vl-|4o|omni|glm-4v|internvl|gemini|pixtral|llava|minicpm-v|doubao-vision|claude-[3-9]|claude-(sonnet|opus|haiku)-[4-9])/i;

function isVisionModelName(id: string): boolean {
  return VISION_NAME_RE.test(id);
}

/**
 * 拉取模型列表并过滤为视觉模型（OCR AI 服务商「自动获取」用）。
 * 宽松策略：过滤结果非空 → 只给视觉模型；为空（响应无标注特征或目录未知）→ 返回全量，
 * 避免严格的白名单把本可用的模型挡在外面。
 */
export async function fetchVisionModels(baseUrl: string, apiKey: string,
  aiFormat: string): Promise<ModelListResult> {
  const r = aiFormat === 'anthropic'
    ? await fetchAnthropicModels(baseUrl, apiKey)
    : await fetchOpenAiModels(baseUrl, apiKey);
  if (r.error.length > 0 || r.models.length === 0) {
    return r;
  }
  const vision: string[] = r.models.filter((m: string): boolean => isVisionModelName(m));
  if (vision.length === 0) {
    return r;
  }
  return { models: vision, error: '' };
}
