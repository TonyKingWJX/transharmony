import { postJson, truncate } from '../utils/HttpClient';
import { sha256Hex, hmacSha256Hex, hmacSha256Raw, utf8 } from '../utils/HashUtil';
import { safeParse, getStr, getObj, getArr } from '../utils/JsonUtil';
import { settingsStore, ServiceItem } from './SettingsStore';
import { findDef, ProviderDef } from './ProviderCatalog';
import { devLogStore } from './DevLogStore';

/**
 * 本机 OCR 执行器（文字识别服务实例，与插件 OCR 并列的云端通道）：
 *  - tencent-ocr：腾讯云 GeneralBasicOCR（ocr.tencentcloudapi.com，TC3-HMAC-SHA256 签名，同翻译适配器）；
 *  - baidu-ocr：百度智能云通用文字识别标准版（API Key/Secret Key 换 access_token，token 内存缓存）；
 *  - ocr-ai：视觉多模态模型识别图片文字（OpenAI chat images / Anthropic messages images，按 aiFormat 分流）。
 * 入参统一为 JPEG base64（调用方负责 PixelMap 压缩打包），返回按行拼接的识别文本。
 */

const AI_OCR_PROMPT = '请提取图片中的全部文字，按原始行序逐行输出；不要翻译、不要解释、不要输出任何其他内容。';

/**
 * 连通测试图：160×64 白底黑字「鸿译OCR 123」JPEG（约 3KB）。
 * 纯白图会被腾讯 OCR 判 ImageNoText 失败，带清晰印刷体文字才能真实测通识别链路；
 * 开发期由 tools 脚本（System.Drawing）生成，base64 内嵌保证确定性。
 */
const TEST_IMAGE_JPEG_B64 = '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCABAAKADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9U6KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACuW8E/E3w58QrvX7PRb5pr/Qb5tP1OxuIJLe4tZhyu+ORVYK64dHxtdSCpIrqa+Pv2jrPxbqv7Nvju8+IGjW+m+K/DeoRW+m+IdAu5LeDUreW5tcXMaLJ5kTGNhG8chbDI21mUg0AfRXjr4z+DfhvrGgaV4g1y2stQ1u+XT7S3Lgv5jRSShnA+4m2Jsu2FHAzyK3Z/GOkJ4b1DXbe9TU9NsYZZ5pNMzdsRGpZlVY9xdsDhVBJJAAya+L9W8BW+j/tQ/FCz8M6fMkulaN4bltLeLSE1hWVpL9pYpYpm3GJ8nLI6urbCDgYPtH7OPhjxZ8O/hl4w1OXwcbTU/EHi7U9csvDLzQWslrZzThYEkKs8av5SK5UE4LY65oA9Avf2gvh5p3gHQ/G114psoPCutpG9hqjb/Km34CDIGVYkhdrYO75cZ4qnfftL/DTTLKe8vPFEVpaQI0s089rOkcaAZLMxTAAHJJryD4Zax4O+I37ONwnhb4NazrHhzx5e6rLf+HEurdbaGY3ktvcF5ZZ0SFC8JcCEEjO5ULdeMt/APxb+IM1p4L+J2rad438HeGfLk1rwZ4RvVk1a63OJbGLU7m6FvHcxCJQX8sRGVlJKsDyAfaOi67p/iLQrDWdNu47vS762jvLa6jPySwuodHB9CpB/GvLbn9sP4HWfiFtDn+LHhKLUlkMTRNq0IVHBwVZ92wEEYwT1ry/9tbU7/wAc+B/hd8NNPlvvClh8R/FNvoer5HkXMemIkklxAu04UyCNV6kMpKkEMRXsUX7MPwkh8Cjwavw48Nf8I15XlfYG02Igj+8WI3F88787s85zzQB6ZDNHcRJLE6yROoZXQ5DA8gg9xXnPxH/aT+Ffwh1RNM8ZeP8Aw/4e1RlD/YLy+RbgIfusYgSwU4OGIwcV8r/BP4j67+zl+z1+0poCX0msW/wm1TULbwxLfP5zRWrQLLaQOTyyxsw6noSowAAPZv2WP2X/AAb4E+F+i6zq+i2Hifx34htItV1/xLq0CXd3e3c6iSX944JEYZsKowMAEgkkkA9VvvjZ4B0/4bP8QZfF+jt4IQIW1+G7SW0G6QRL+8Ukf6xlTHYnBrnfAv7WHwc+JfiC30Lwx8SfDmr6zcEiCwhvkE05AJIjVsFzgE4XJwCa8R/4KMeB/D3w/wD+Cf8A8UNM8M6LY6Bprz6fcmz06BYIRI+qWhdgigKCTycAZOT3rzb4o+Ovh7+1z4p8JfDz4TeBp9K+IGmazY6/Lr+o6RHo02hWME6PLcIJNs0pbCqERSpLKWIIXIB+h9VNX1ex0DS7vUtTvLfTtOtImnuLu6lWOKGNRlndmICqAMkmrdfJ/wDwUJ+BOlfEf4J+OPFmt63r0lt4c8L3s9l4dttQeDTHu0VpI7qaJMGWRCFC7jtAB+U5oA+odA17T/FWg6brWkXcWoaVqVtHeWd3CcpPDIodHU9wysCPrXntr+1J8Ib7xx/wh9v8SvDM3ibzzbf2cmpxGQzA4MQOcGTPGwHdkYxmqX7MFhFqv7I/wlsp9/kXPgfSYZPLYq21rCIHBHIOD1rwD9tT4cfCbw/8EoPg74O8B6DP8Q9eMNt4T0LSLBBeW0plXdfF0UvDHGu93mcgMAwZjlqAPrzx38Q/C/ww8Pya54u8Qab4b0iNgjXmp3KQRlj0UFiMscHCjk9hVH4bfF3wV8YdJm1PwR4p0rxRZQSeVNLpl0s3kvjIVwDlCRyAwGRzXMfFxvCHgr4aaTrvxG0N/GkXhxrd0ZNJOpzi6IEPnxwgMd3zt8wGVDE56189/sjal4S+LP7V/wASPib4DsbfwdoMWg2/h+68MSJDaX95eC4aRtQuLNCWhAVREhkAZ/mOBQB9tUUUUAFfGnh34d+NP2ovCPxPC+Oo9H8FeJfGmowgTWMl7dR2ljLBbQCzLTrDArS2c0jExvu3jgHJP2XUcFvFbR7IY0iTczbUUKMkkk4Hckkn3NAHzJ4m+CL6BrJv9e1Twlr+p3Mfk/8ACSeMLt7PVL+NWLhJfsohiKxmUqqogCrtzk5Jm/Y/ghm8bfGq/wBLuVvPDf8AbdhYWE1leSXGn+bBptuLxbUuzfILl5gSOrZB5Bx9D6x4b0jxCIhqul2WpiLJjF5bpLszjONwOM4H5Vas9OtNPsks7W1htrRF2pbwxhI1HoFHAFAHw5+xh4j0n4i/sr6H4U0rw6vjy60HV9Tl1O1j1E2SWUkupXzwfveA7NE+7apOFdCR8y0z4Z/Drzv2hPjPB/wqL7T5P9i/6J/wku37Nm0c/f3fPu6+3Svtfwp4R0PwLoNponhzSLHQtHtF2wWGnW6wQxjOTtRQAMnk+pNO07wrpOk67q+tWdhDb6rq/k/b7tBh7jylKR7j32qSBQB4b8cfgRrfxn+CWgWehQw+AvHfhLU7fXfDP2m5+1w213alhEkrr96ORCyn72NwJDbcHmB+0j+0MukjSW/Zlvj4z/1Juh4itP7F3Zx53nZ37P4vLxux8u7PNfV1FAHzn8EP2U38NfArxv4V+IWpR694o+Is1/f+LdQsSyxtPdoUdICwyEjTAU4HIJAGcDgPhl44/aB/Zs8LWHw88T/CK7+Kmm6FAljo/i7wnqUCG8tYxthW4t5mDRuqBQWyQcfxYLN9l0UAfIv7V3h74o/H/wDYR8b6VdfD86N461aWza18LWd/HezJDHqNtIN8o2oX8tGdgOBjGTiux/bE+EXiPxRo3hv4jfDm1Wb4p+Ab0alpMQIQ6jbN8t1YO3dZYycD+8AARuJr6JooAzPDWry6/wCHtN1K40660i4u7eOeTT71QJ7ZmUFo3AJG5SSDgkccEiuA/am8Mar41/Zu+JmgaHZSalrGp+Hr20s7SHG+aV4WVUGeMkkCvUqKAPGfhtZ+K/hr+xx4WtLPQ5LnxxoHgK1ih0OQgPJqEGnqFtic4yZUCelfNv7PXjLx38GNClv9S/Zq8feIviPrSpP4m8W3FzZPc6lc4GQGaXKwp92OJcKqqMKDmvviigDx/wCInxZ+IXhfwf4Q8R+HPhLqHiz+0YVl1rQYtSgt9S0nfErqArnZMVYtG6qw5wQSAa8y+EfhL4h/Fb9qP/hc/izwIPhdo2l+HJPD1hpt1eRT6pqpkmWUy3BiJVIk2kLGxyG+bkHj6tooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD/9k=';

/** 连通测试结果（ServiceConfigPage 用，结构与翻译页 TestResult 一致） */
export interface OcrTestResult {
  ok: boolean;
  message: string;
}

function trimSlash(s: string): string {
  return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}

export class OcrEngine {
  /** 百度 access_token 内存缓存（凭 key:secret 归属校验，换凭证即重新获取） */
  private static baiduToken: string = '';
  private static baiduTokenOwner: string = '';

  /** 识别入口：按实例 defId 分发（错误统一采集日志，由调用方 toast） */
  static async recognize(serviceId: string, imageB64: string): Promise<string> {
    const s = settingsStore.getServiceIn('ocr', serviceId);
    if (s === undefined) {
      throw new Error('未找到该文字识别服务实例');
    }
    if (!s.enabled) {
      throw new Error('「' + s.name + '」已停用，请在偏好设置中重新选择');
    }
    const def = findDef(s.defId);
    if (def === undefined) {
      throw new Error('未找到该服务商定义');
    }
    const started = Date.now();
    let text = '';
    if (s.defId === 'tencent-ocr') {
      text = await OcrEngine.tencentOcr(s, imageB64);
    } else if (s.defId === 'baidu-ocr') {
      text = await OcrEngine.baiduOcr(s, imageB64);
    } else {
      text = await OcrEngine.aiVisionOcr(s, def, imageB64);
    }
    devLogStore.append('info', 'ocr', '识别成功：' + s.name + ' 耗时' + (Date.now() - started) + 'ms');
    return text;
  }

  /** 连通测试：OCR 用内置文字测试图实测一次识别（真实走完整识别链路）；AI 走文本连通请求 */
  static async testService(serviceId: string): Promise<OcrTestResult> {
    const s = settingsStore.getServiceIn('ocr', serviceId);
    if (s === undefined) {
      const miss: OcrTestResult = { ok: false, message: '未找到该服务实例' };
      return miss;
    }
    const def = findDef(s.defId);
    if (def === undefined) {
      const noDef: OcrTestResult = { ok: false, message: '未找到该服务商定义' };
      return noDef;
    }
    const started = Date.now();
    try {
      if (s.defId === 'baidu-ocr') {
        const text = await OcrEngine.baiduOcr(s, TEST_IMAGE_JPEG_B64);
        const ok: OcrTestResult = { ok: true, message: '连通正常 · ' + (Date.now() - started) + 'ms · 识别: ' + OcrEngine.snippet(text) };
        return ok;
      }
      if (s.defId === 'tencent-ocr') {
        const text = await OcrEngine.tencentOcr(s, TEST_IMAGE_JPEG_B64);
        const ok: OcrTestResult = { ok: true, message: '连通正常 · ' + (Date.now() - started) + 'ms · 识别: ' + OcrEngine.snippet(text) };
        return ok;
      }
      // AI 视觉：文本连通测试验证 Key/地址/模型可达，识别能力以实际识别为准
      await OcrEngine.aiVisionOcr(s, def, '');
      const ok: OcrTestResult = { ok: true, message: '连通正常 · ' + (Date.now() - started) + 'ms' };
      return ok;
    } catch (e) {
      const fail: OcrTestResult = { ok: false, message: e instanceof Error ? e.message : '测试失败，请检查网络与凭证' };
      devLogStore.append('error', 'ocr', '连通测试失败：' + s.name + '：' + fail.message);
      return fail;
    }
  }

  /** 日志/提示用文本摘要：压平换行、限 40 字符 */
  private static snippet(text: string): string {
    const flat = text.replace(/\s+/g, ' ').trim();
    return flat.length <= 40 ? flat : flat.substring(0, 40) + '…';
  }

  // ---- 腾讯云 GeneralBasicOCR（TC3 签名，与 TencentAdapter 同规格）----

  private static async tencentOcr(s: ServiceItem, imageB64: string): Promise<string> {
    const secretId = s.config['secretId'] ?? '';
    const secretKey = s.config['secretKey'] ?? '';
    if (secretId.length === 0 || secretKey.length === 0) {
      throw new Error('请先在配置页填写腾讯云 SecretId / SecretKey');
    }
    const host = 'ocr.tencentcloudapi.com';
    const service = 'ocr';
    const version = '2018-11-19';
    // OCR 为地域性服务，广州地域开放通用印刷体识别
    const region = 'ap-guangzhou';
    const payload = JSON.stringify({ ImageBase64: imageB64 });
    const now = new Date();
    const timestamp = Math.floor(now.getTime() / 1000);
    const date = now.toISOString().substring(0, 10);

    const canonicalRequest = 'POST\n/\n\n'
      + 'content-type:application/json; charset=utf-8\n'
      + 'host:' + host + '\n'
      + 'x-tc-action:generalbasicocr\n'
      + '\n'
      + 'content-type;host;x-tc-action\n'
      + await sha256Hex(payload);
    const stringToSign = 'TC3-HMAC-SHA256\n'
      + timestamp + '\n'
      + date + '/' + service + '/tc3_request\n'
      + await sha256Hex(canonicalRequest);
    const kDate = await hmacSha256Raw(utf8('TC3' + secretKey), date);
    const kService = await hmacSha256Raw(kDate, service);
    const kSigning = await hmacSha256Raw(kService, 'tc3_request');
    const signature = await hmacSha256Hex(kSigning, stringToSign);
    const authorization = 'TC3-HMAC-SHA256 '
      + 'Credential=' + secretId + '/' + date + '/' + service + '/tc3_request, '
      + 'SignedHeaders=content-type;host;x-tc-action, '
      + 'Signature=' + signature;

    const resp = await postJson({
      url: 'https://' + host,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Host': host,
        'X-TC-Action': 'GeneralBasicOCR',
        'X-TC-Version': version,
        'X-TC-Region': region,
        'X-TC-Timestamp': timestamp.toString(),
        'Authorization': authorization
      },
      body: payload,
      timeoutMs: 30000,
      allowHttpError: true
    });
    const root = safeParse(resp.body);
    if (root === null) {
      throw new Error('腾讯OCR响应解析失败: ' + truncate(resp.body, 120));
    }
    const response = getObj(root, 'Response');
    if (response === null) {
      throw new Error('腾讯OCR响应缺少 Response');
    }
    const err = getObj(response, 'Error');
    if (err !== null) {
      const code = getStr(err, 'Code');
      const msg = getStr(err, 'Message');
      throw new Error('腾讯OCR错误 ' + code + '：' + msg);
    }
    const lines: string[] = [];
    for (const it of getArr(response, 'TextDetections')) {
      const t = getStr(it, 'DetectedText');
      if (t.length > 0) {
        lines.push(t);
      }
    }
    return lines.join('\n');
  }

  // ---- 百度通用文字识别（标准版）----

  private static async getBaiduToken(apiKey: string, secretKey: string): Promise<string> {
    if (apiKey.length === 0 || secretKey.length === 0) {
      throw new Error('请先在配置页填写百度 API Key / Secret Key');
    }
    const owner = apiKey + ':' + secretKey;
    if (OcrEngine.baiduToken.length > 0 && OcrEngine.baiduTokenOwner === owner) {
      return OcrEngine.baiduToken;
    }
    const url = 'https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id='
      + encodeURIComponent(apiKey) + '&client_secret=' + encodeURIComponent(secretKey);
    const resp = await postJson({
      url: url,
      headers: { 'Content-Type': 'application/json' },
      body: '',
      timeoutMs: 15000
    });
    const root = safeParse(resp.body);
    const token = root !== null ? getStr(root, 'access_token') : '';
    if (token.length === 0) {
      throw new Error('获取 access_token 失败：' + truncate(resp.body, 120));
    }
    OcrEngine.baiduToken = token;
    OcrEngine.baiduTokenOwner = owner;
    return token;
  }

  private static async baiduOcr(s: ServiceItem, imageB64: string): Promise<string> {
    const token = await OcrEngine.getBaiduToken(s.config['apiKey'] ?? '', s.config['secretKey'] ?? '');
    const resp = await postJson({
      url: 'https://aip.baidubce.com/rest/2.0/ocr/v1/general_basic?access_token=' + encodeURIComponent(token),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'image=' + encodeURIComponent(imageB64),
      timeoutMs: 30000,
      allowHttpError: true
    });
    const root = safeParse(resp.body);
    if (root === null) {
      throw new Error('百度OCR响应解析失败: ' + truncate(resp.body, 120));
    }
    const errCode = root['error_code'];
    if (errCode !== undefined && errCode !== null) {
      throw new Error('百度OCR错误 ' + String(errCode) + '：' + getStr(root, 'error_msg'));
    }
    const lines: string[] = [];
    for (const it of getArr(root, 'words_result')) {
      const t = getStr(it, 'words');
      if (t.length > 0) {
        lines.push(t);
      }
    }
    return lines.join('\n');
  }

  // ---- AI 视觉模型（OpenAI chat images / Anthropic messages images）----

  private static async aiVisionOcr(s: ServiceItem, def: ProviderDef, imageB64: string): Promise<string> {
    const cfg = s.config;
    const base = trimSlash((cfg['baseUrl'] ?? '').length > 0 ? cfg['baseUrl'] : def.baseUrl);
    if (base.length === 0) {
      throw new Error('请先在配置页填写 API 地址');
    }
    const model = (cfg['model'] ?? '').length > 0 ? cfg['model'] : def.defaultModel;
    if (model.length === 0) {
      throw new Error('请先在配置页选择模型');
    }
    const apiKey = cfg['apiKey'] ?? '';
    return def.aiFormat === 'anthropic'
      ? await OcrEngine.anthropicVision(base, model, apiKey, imageB64)
      : await OcrEngine.openAiVision(base, model, apiKey, imageB64);
  }

  private static async openAiVision(base: string, model: string, apiKey: string,
    imageB64: string): Promise<string> {
    const parts: Array<Object> = [{ 'type': 'text', 'text': AI_OCR_PROMPT } as Record<string, string>];
    if (imageB64.length > 0) {
      const imageUrl: Record<string, string> = { 'url': 'data:image/jpeg;base64,' + imageB64 };
      parts.push({ 'type': 'image_url', 'image_url': imageUrl } as Record<string, Object>);
    } else {
      parts.push({ 'type': 'text', 'text': '连接测试，请回复：OK' } as Record<string, string>);
    }
    const msg: Record<string, Object> = { 'role': 'user', 'content': parts };
    const body: Record<string, Object> = { 'model': model, 'messages': [msg] };
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (apiKey.length > 0) {
      headers['Authorization'] = 'Bearer ' + apiKey;
    }
    const resp = await postJson({
      url: base + '/chat/completions',
      headers: headers,
      body: JSON.stringify(body),
      timeoutMs: 60000
    });
    const root = safeParse(resp.body);
    if (root === null) {
      throw new Error('AI 响应解析失败: ' + truncate(resp.body, 120));
    }
    const choices = getArr(root, 'choices');
    if (choices.length === 0) {
      throw new Error('AI 响应缺少 choices: ' + truncate(resp.body, 120));
    }
    const message = getObj(choices[0], 'message');
    if (message === null) {
      throw new Error('AI 响应缺少 message');
    }
    return OcrEngine.extractOpenAiContent(message['content']);
  }

  /** OpenAI content 兼容解析：字符串直接返回；分段数组拼接 text 部分（部分兼容服务返回数组） */
  private static extractOpenAiContent(content: Object | null): string {
    if (content === null || content === undefined) {
      return '';
    }
    if (typeof content === 'string') {
      return content;
    }
    if (Array.isArray(content)) {
      let out = '';
      for (let i = 0; i < content.length; i++) {
        const it: Object = content[i];
        if (typeof it === 'object' && it !== null) {
          const rec = it as Record<string, Object | null>;
          if (getStr(rec, 'type') === 'text') {
            out += getStr(rec, 'text');
          }
        }
      }
      return out;
    }
    return '';
  }

  private static async anthropicVision(base: string, model: string, apiKey: string,
    imageB64: string): Promise<string> {
    const parts: Array<Object> = [];
    if (imageB64.length > 0) {
      const source: Record<string, string> = {
        'type': 'base64', 'media_type': 'image/jpeg', 'data': imageB64
      };
      parts.push({ 'type': 'image', 'source': source } as Record<string, Object>);
    }
    parts.push({ 'type': 'text', 'text': imageB64.length > 0 ? AI_OCR_PROMPT : '连接测试，请回复：OK' } as Record<string, string>);
    const msg: Record<string, Object> = { 'role': 'user', 'content': parts };
    const body: Record<string, Object> = { 'model': model, 'max_tokens': 4096, 'messages': [msg] };
    const resp = await postJson({
      url: base + '/v1/messages',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify(body),
      timeoutMs: 60000
    });
    const root = safeParse(resp.body);
    if (root === null) {
      throw new Error('AI 响应解析失败: ' + truncate(resp.body, 120));
    }
    const errType = getStr(root, 'type');
    if (errType === 'error') {
      const err = getObj(root, 'error');
      throw new Error(err !== null ? getStr(err, 'message') : 'AI 请求失败');
    }
    let out = '';
    for (const it of getArr(root, 'content')) {
      if (getStr(it, 'type') === 'text') {
        out += getStr(it, 'text');
      }
    }
    return out;
  }
}
