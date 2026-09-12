// Mock Bob 翻译插件（与标准 Bob 插件同形态：supportLanguages + translate(query, completion)）
function supportLanguages() {
  return ['auto', 'zh-Hans', 'en', 'ja'];
}

function translate(query, completion) {
  $log.info('mock translate: ' + query.text + ' apiKey=' + $option.apiKey);
  $http.request({
    method: 'GET',
    url: 'https://www.baidu.com/',
    header: { 'X-Api-Key': $option.apiKey },
    timeout: 15,
    handler: function (resp) {
      if (resp.error) {
        completion({ error: resp.error });
        return;
      }
      completion({
        result: {
          from: query.from,
          to: query.to,
          toParagraphs: [
            '[from .bobplugin] status=' + resp.response.statusCode +
              ' len=' + String(resp.data).length,
            'plugin=' + $info.name + ' v' + $info.version
          ]
        }
      });
    }
  });
}
