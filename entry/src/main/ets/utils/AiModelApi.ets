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
