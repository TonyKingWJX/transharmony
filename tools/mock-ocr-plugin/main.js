// Mock Bob OCR 插件（标准形态：ocr(query, completion)）
// 用途：验证宿主 OCR 执行层 —— 图片数据完整送达插件（字节计数回显）、texts 形态解析、UI 链路
function supportLanguages() {
  return ['auto', 'zh-Hans', 'en', 'ja'];
}

function ocr(query, completion) {
  $log.info('mock-ocr: from=' + query.from + ' detectFrom=' + query.detectFrom);
  var size = query.image && typeof query.image.length === 'number' ? query.image.length : 0;
  var hexHead = query.image ? query.image.toHex().substring(0, 8) : 'none';
  completion({
    result: {
      from: query.detectFrom,
      texts: [
        '[mock-ocr] 图片数据已送达：' + size + ' 字节',
        '[mock-ocr] 数据头4字节(hex)=' + hexHead,
        '模拟识别结果 · 第一行',
        '模拟识别结果 · 第二行 Mock OCR Line 2'
      ]
    }
  });
}
