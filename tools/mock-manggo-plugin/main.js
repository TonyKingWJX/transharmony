// manggo Mock 插件（ES Module，联调宿主用）：
//  - translate：文本回显/大写，演示 options.config、options.detect、options.setResult 流式；
//  - recognize：返回图片 base64 长度，验证 PNG 入参与 promise 调用链；
//  - tts：合成 1 秒正弦提示音 WAV，返回 {bytes, format}，验证音频归一化（Uint8Array → base64）。

const LANG_LABEL = {
  'zh-Hans': '中', 'en-US': 'EN', 'ja-JP': '日', 'ko-KR': '韩',
  'fr-FR': '法', 'de-DE': '德', 'ru-RU': '俄', 'es-ES': '西', 'th-TH': '泰', 'vi-VN': '越'
};

export async function translate(text, from, to, options) {
  const prefix = (typeof options.config.echoPrefix === 'string' && options.config.echoPrefix.length > 0)
    ? options.config.echoPrefix : '[M]';
  const vendor = typeof options.config.vendor === 'string' ? options.config.vendor : 'echo';
  const key = typeof options.config.apiKey === 'string' ? options.config.apiKey : '';
  const lang = LANG_LABEL[to] || to;
  let body = vendor === 'upper' ? text.toUpperCase() : text;

  if (options.config.enableStream === true && typeof options.setResult === 'function') {
    // 流式：分片发送（宿主累积展示），首片延迟 200ms 模拟真实接口
    await new Promise(function (resolve) { setTimeout(resolve, 200); });
    const head = prefix + ' ' + lang + '·' + (key ? '(密钥OK)' : '(无密钥)') + ' ';
    options.setResult(head);
    const chunk = 8;
    for (let i = 0; i < body.length; i += chunk) {
      options.setResult(body.substring(i, i + chunk));
      await new Promise(function (resolve) { setTimeout(resolve, 30); });
    }
    body = head + body;
  }
  // 返回完整字符串（最终结果以返回值为准）
  return prefix + ' ' + lang + '·' + (key ? '(密钥OK)' : '(无密钥)') + ' ' + body;
}

export async function recognize(base64, language, options) {
  const lang = language === 'auto' ? 'auto' : (LANG_LABEL[language] || language);
  // 宿主按 manggo 约定传 PNG base64（无 data: 前缀）
  return `[Manggo OCR·${lang}] PNG base64 长度 ${base64.length}（宿主链路 OK，utils.osType=${options.utils.osType}）`;
}

function writeAscii(view, offset, s) {
  for (let i = 0; i < s.length; i++) { view.setUint8(offset + i, s.charCodeAt(i)); }
}

export async function tts(text, language, options) {
  const sampleRate = 8000;
  const seconds = 1;
  const n = sampleRate * seconds;
  const dataLen = n * 2;
  const buf = new ArrayBuffer(44 + dataLen);
  const view = new DataView(buf);
  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataLen, true);
  writeAscii(view, 8, 'WAVE');
  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(view, 36, 'data');
  view.setUint32(40, dataLen, true);
  for (let i = 0; i < n; i++) {
    view.setInt16(44 + i * 2, Math.round(Math.sin(i / 16) * 6000), true);
  }
  // 测 {bytes, format} 归一化路径（也可以直接返回 Uint8Array / ArrayBuffer / base64 字符串）
  return { bytes: new Uint8Array(buf), format: 'audio/wav' };
}
