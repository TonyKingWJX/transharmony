import pluginHost from 'libpluginhost.so';
import { HttpBridge } from '../services/plugin/HttpBridge';
import { PluginInstaller, InstalledPlugin } from '../services/plugin/PluginInstaller';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 插件实验室（开发调试页 · spike 阶段专用，验证完成后移除）：
 *  - JSVM 连通性测试：native 桥 + JS async/await + 消息泵 + 结果回传（runTest）
 *  - ESM 语法探针：实测 JSVM 是否接受 ES Module 语法，决定 Manggo 插件（强制 ESM）加载方案（esmProbe）
 *  - 自定义脚本：在 JSVM 沙盒跑任意 JS，可调用 nativeEcho / nativeFetch / __complete
 */

@Component
export struct PluginLabPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  @State resultText: string = '尚未运行';
  @State running: boolean = false;
  @State scriptInput: string = '';
  @State runtimeLog: string = '尚未运行';
  @State runtimeRunning: boolean = false;
  @State bobLog: string = '尚未运行';
  @State bobRunning: boolean = false;
  @State installLog: string = '尚未运行';
  @State installRunning: boolean = false;
  /** 插件 $log 实时输出（registerLogHandler 回投，全插件共享，最多保留 40 行） */
  @State pluginLog: string = '';

  aboutToAppear(): void {
    // HTTP 桥注册：让插件沙盒的 nativeHttp 走真实网络
    HttpBridge.register();
    // 插件 $log 回投：native hilog 之外的页面内可见日志
    pluginHost.registerLogHandler((logJson: string): void => {
      try {
        const entry = JSON.parse(logJson) as Record<string, string>;
        const line = '[' + (entry['level'] ?? 'info') + '] ' + (entry['message'] ?? '');
        const lines = this.pluginLog === '' ? [] : this.pluginLog.split('\n');
        lines.push(line);
        this.pluginLog = lines.slice(-40).join('\n');
      } catch (e) {
        // 忽略解析失败
      }
    });
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 常驻 Runtime 全链路测试：init → load → sync/promise/callback 三种调用 → 超时 → 废弃调用后存活 */
  /** .bobplugin 安装管线测试：rawfile zip → 解压校验落盘 → 登记加载 → 按标准入口调用 */
  private async runInstallTest(): Promise<void> {
    if (this.installRunning) {
      return;
    }
    this.installRunning = true;
    const lines: string[] = [];
    const step = async (name: string, fn: () => Promise<string>): Promise<void> => {
      try {
        const r: string = await fn();
        lines.push(`[OK] ${name}: ${r}`);
      } catch (e) {
        lines.push(`[REJECT] ${name}: ${(e instanceof Error) ? e.message : String(e)}`);
      }
    };
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let installed: InstalledPlugin | null = null;
      await step('installFromRawfile(mock.bobplugin)', async (): Promise<string> => {
        installed = await PluginInstaller.installFromRawfile(ctx, 'mock.bobplugin');
        const rec: InstalledPlugin = installed;
        return `${rec.pluginId} v${rec.version} (${rec.category}) ${rec.name}`;
      });
      await step('initRuntime', () => pluginHost.initRuntime());
      await step('loadInstalled', async (): Promise<string> => {
        const rec: InstalledPlugin = installed!;
        return await PluginInstaller.loadInstalled(ctx, rec);
      });
      await step('sync supportLanguages', () =>
        pluginHost.callPluginFn('com.transharmony.mock', 'supportLanguages', '[]', 'sync', 2000));
      await step('callback translate', () => pluginHost.callPluginFn(
        'com.transharmony.mock', 'translate',
        '[{"text":"bobplugin 测试","from":"auto","to":"zh-Hans"}]', 'callback', 25000));
    } catch (e) {
      lines.push('[FATAL] ' + ((e instanceof Error) ? e.message : String(e)));
    } finally {
      this.installLog = lines.join('\n');
      this.installRunning = false;
    }
  }

  /** Bob shim 全家桶测试：$http(handler式) + $option + $info + $env + $data + $signal + $timer + $log */
  private async runBobShimTest(): Promise<void> {
    if (this.bobRunning) {
      return;
    }
    this.bobRunning = true;
    const lines: string[] = [];
    const step = async (name: string, fn: () => Promise<string>): Promise<void> => {
      try {
        const r: string = await fn();
        lines.push(`[OK] ${name}: ${r}`);
      } catch (e) {
        lines.push(`[REJECT] ${name}: ${(e instanceof Error) ? e.message : String(e)}`);
      }
    };
    // 模拟 Bob 翻译插件：官方入口形态 supportLanguages() + translate(query, completion)
    const bobPluginScript = `
function supportLanguages() { return ['auto', 'zh-Hans', 'en', 'ja']; }
function translate(query, completion) {
  $log.info('translate: ' + query.text + ' apiKey=' + $option.apiKey);
  $http.request({
    method: 'GET',
    url: 'https://www.baidu.com/',
    header: { 'X-Api-Key': $option.apiKey },
    timeout: 15,
    handler: function (resp) {
      if (resp.error) { completion({ error: resp.error }); return; }
      var dataOk = $data.isData(resp.rawData) && resp.rawData.toBase64().length > 0;
      completion({ result: {
        from: query.from, to: query.to,
        toParagraphs: [
          'status=' + resp.response.statusCode,
          'dataJson=' + (typeof resp.data),
          'dataOk=' + dataOk,
          'hdr=' + (resp.response.headers['date'] || '-'),
          'info=' + ($info.name || '?') + '/' + $env.appVersion,
          'lang=' + supportLanguages().length
        ]
      } });
    }
  });
}
$timer.schedule({ interval: 0.05, repeats: false, handler: function () { $log.info('timer fired'); } });
$log.info('plugin loaded, name=' + ($info.name || '?') + ' b64=' + $data.fromUTF8('abc').toBase64());
`;
    const info: Record<string, string> = { 'name': 'mock-bob-plugin', 'version': '1.0.0' };
    const option: Record<string, string> = { 'apiKey': 'test-key-123' };
    const configObj: Record<string, Object> = { 'info': info, 'option': option };
    const config = JSON.stringify(configObj);
    try {
      await step('initRuntime', () => pluginHost.initRuntime());
      await step('loadPlugin(bobmock)', () => pluginHost.loadPlugin('bobmock', bobPluginScript, config));
      await step('sync supportLanguages', () => pluginHost.callPluginFn('bobmock', 'supportLanguages', '[]', 'sync', 2000));
      await step('callback translate', () => pluginHost.callPluginFn(
        'bobmock', 'translate',
        '[{"text":"hello","from":"auto","to":"zh-Hans"}]', 'callback', 25000));
    } catch (e) {
      lines.push('[FATAL] ' + ((e instanceof Error) ? e.message : String(e)));
    } finally {
      this.bobLog = lines.join('\n');
      this.bobRunning = false;
    }
  }

  private async runRuntimeTest(): Promise<void> {
    if (this.runtimeRunning) {
      return;
    }
    this.runtimeRunning = true;
    const lines: string[] = [];
    const step = async (name: string, fn: () => Promise<string>): Promise<void> => {
      try {
        const r: string = await fn();
        lines.push(`[OK] ${name}: ${r}`);
      } catch (e) {
        lines.push(`[REJECT] ${name}: ${(e instanceof Error) ? e.message : String(e)}`);
      }
    };
    const testScript = `
var counter = 0;
function addSync(a, b) { counter = counter + 1; return a + b; }
function promiseWork() {
  return nativeHttp('{"url":"https://www.baidu.com/"}').then(function (r) {
    var resp = JSON.parse(r);
    return 'status:' + resp.status + ' len:' + resp.body.length + ' date:' + (resp.headers['date'] || '-');
  });
}
function cbWork(arg, completion) { counter = counter + 1; completion({ echoed: arg, counter: counter }); }
function dictWork(query, completion) {
  completion({ result: {
    from: query.from, to: query.to,
    toDict: {
      word: 'love',
      phonetics: [{ type: 'us', value: '/lʌv/' }],
      parts: [{ part: 'n.', means: ['爱', '恋爱'] }, { part: 'v.', means: ['热爱'] }],
      exchanges: [{ name: '过去式', words: ['loved'] }],
      additions: [{ name: '标签', value: 'CET4' }]
    }
  }});
}
function fileWork(query, completion) {
  var out = [];
  try {
    out.push('dir=' + (typeof __phSandboxDir === 'string' ? __phSandboxDir : 'UNDEFINED'));
    out.push('dirExists=' + $file.exists('$sandbox'));
    out.push('dirIsDir=' + $file.isDirectory('$sandbox'));
    var w = $file.write({ data: $data.fromUTF8('plugin-file-test'), path: '$sandbox/demo.txt' });
    out.push('write=' + w);
    out.push('existsAfter=' + $file.exists('$sandbox/demo.txt'));
    try { out.push('read=' + $file.read('$sandbox/demo.txt').toUTF8()); }
    catch (er) { out.push('readErr=' + er); }
    out.push('list=' + JSON.stringify($file.list('$sandbox')));
    out.push('copy=' + $file.copy({ src: '$sandbox/demo.txt', dst: '$sandbox/demo2.txt' }));
    out.push('move=' + $file.move({ src: '$sandbox/demo2.txt', dst: '$sandbox/demo3.txt' }));
    try { out.push('movedRead=' + $file.read('$sandbox/demo3.txt').toUTF8()); }
    catch (em) { out.push('read2Err=' + em); }
    out.push('delete=' + $file.delete('$sandbox/demo3.txt'));
  } catch (ex) {
    out.push('fatal=' + ex);
  }
  completion({ result: { from: query.from, to: query.to, toParagraphs: out } });
}
function hangWork() { return new Promise(function () {}); }
`;
    try {
      await step('initRuntime', () => pluginHost.initRuntime());
      await step('loadPlugin(test)', async (): Promise<string> => {
        // $file 用例需要真实目录：与 PluginInstaller.loadInstalled 同规格
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const pluginDir = `${ctx.filesDir}/plugins/test`;
        const sandboxDir = `${ctx.filesDir}/plugin_sandbox/test`;
        try {
          if (!fileIo.accessSync(sandboxDir)) {
            fileIo.mkdirSync(sandboxDir, true);
          }
        } catch (e) {
          // 已存在等场景忽略
        }
        return await pluginHost.loadPlugin('test', testScript, '', '', pluginDir, sandboxDir,
          ctx.applicationInfo.name);
      });
      await step('sync addSync[2,3]', () => pluginHost.callPluginFn('test', 'addSync', '[2, 3]', 'sync', 2000));
      await step('promise promiseWork(真实HTTP→baidu)', () => pluginHost.callPluginFn('test', 'promiseWork', '[]', 'promise', 20000));
      await step('callback cbWork["x"]', () => pluginHost.callPluginFn('test', 'cbWork', '["x"]', 'callback', 3000));
      await step('callback cbWork["y"](状态持久)', () => pluginHost.callPluginFn('test', 'cbWork', '["y"]', 'callback', 3000));
      await step('callback dictWork(toDict词典回退)', () => pluginHost.callPluginFn(
        'test', 'dictWork', '[{"text":"love","from":"en","to":"zh"}]', 'callback', 3000));
      await step('file $file 读写全套', () => pluginHost.callPluginFn(
        'test', 'fileWork', '[{"text":"f","from":"en","to":"zh"}]', 'callback', 5000));
      await step('timeout hangWork(700ms 应超时)', () => pluginHost.callPluginFn('test', 'hangWork', '[]', 'promise', 700));
      await step('sync addSync[10,20](废弃调用后仍存活)', () => pluginHost.callPluginFn('test', 'addSync', '[10, 20]', 'sync', 2000));
    } catch (e) {
      lines.push('[FATAL] ' + ((e instanceof Error) ? e.message : String(e)));
    } finally {
      this.runtimeLog = lines.join('\n');
      this.runtimeRunning = false;
    }
  }

  private async runTest(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    const custom = this.scriptInput.trim();
    try {
      const r: string = custom === ''
        ? await pluginHost.runTest(undefined, 8000)
        : await pluginHost.runTest(custom, 8000);
      this.resultText = '[OK] ' + r;
    } catch (e) {
      this.resultText = '[FAIL] ' + ((e instanceof Error) ? e.message : String(e));
    } finally {
      this.running = false;
    }
  }

  private async runEsmProbe(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      const r: string = await pluginHost.esmProbe();
      this.resultText = '[ESM] ' + r;
    } catch (e) {
      this.resultText = '[ESM-FAIL] ' + ((e instanceof Error) ? e.message : String(e));
    } finally {
      this.running = false;
    }
  }

  build() {
    NavDestination() {
      Column() {
        Blank().height(this.statusBarH)

        // 自定义标题栏
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

          Text('插件实验室')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 12 }) {
            // ── 插件安装（.bobplugin）──
            Column({ space: 10 }) {
              Text('插件安装（.bobplugin zip 管线）')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')

              Button() {
                Row({ space: 8 }) {
                  if (this.installRunning) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color($r('sys.color.ohos_id_color_text_primary_contrary'))
                  }
                  Text(this.installRunning ? '运行中' : '安装内置 mock.bobplugin 并调用')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                }
                .alignItems(VerticalAlign.Center)
              }
                .width('100%')
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.brand'))
                .enabled(!this.installRunning)
                .onClick(() => {
                  this.runInstallTest();
                })

              Text(this.installLog)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor($r('app.color.font_primary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── Bob shim 测试 ──
            Column({ space: 10 }) {
              Text('Bob shim 测试（$http/$option/$info/$env/$data/$timer/$log）')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')

              Button() {
                Row({ space: 8 }) {
                  if (this.bobRunning) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color($r('sys.color.ohos_id_color_text_primary_contrary'))
                  }
                  Text(this.bobRunning ? '运行中' : '运行 Bob shim 测试')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                }
                .alignItems(VerticalAlign.Center)
              }
                .width('100%')
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.brand'))
                .enabled(!this.bobRunning)
                .onClick(() => {
                  this.runBobShimTest();
                })

              Text(this.bobLog)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor($r('app.color.font_primary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
                .textAlign(TextAlign.Start)

              Text('插件 $log 实时输出：')
                .fontSize(11)
                .fontColor($r('app.color.font_tertiary'))
                .width('100%')
              Text(this.pluginLog === '' ? '（空）' : this.pluginLog)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── 常驻 Runtime 测试 ──
            Column({ space: 10 }) {
              Text('常驻 Runtime（正式宿主）')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')

              Button() {
                Row({ space: 8 }) {
                  if (this.runtimeRunning) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color($r('sys.color.ohos_id_color_text_primary_contrary'))
                  }
                  Text(this.runtimeRunning ? '运行中' : '运行 Runtime 测试')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                }
                .alignItems(VerticalAlign.Center)
              }
                .width('100%')
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.brand'))
                .enabled(!this.runtimeRunning)
                .onClick(() => {
                  this.runRuntimeTest();
                })

              Text(this.runtimeLog)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor($r('app.color.font_primary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── spike 探针 ──
            Row({ space: 10 }) {
              Button() {
                Row({ space: 8 }) {
                  if (this.running) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color($r('sys.color.ohos_id_color_text_primary_contrary'))
                  }
                  Text(this.running ? '运行中' : 'JSVM 测试')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
                }
                .alignItems(VerticalAlign.Center)
              }
                .layoutWeight(1)
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.brand'))
                .enabled(!this.running)
                .onClick(() => {
                  this.runTest();
                })
              Button('ESM 探针')
                .layoutWeight(1)
                .backgroundColor($r('app.color.brand'))
                .fontSize(14)
                .enabled(!this.running)
                .onClick(() => {
                  this.runEsmProbe();
                })
            }
            .width('100%')

            // ── 自定义脚本 ──
            Column({ space: 6 }) {
              Text('自定义 JS（留空 = 默认探针脚本；可用 nativeEcho/nativeHttp/__complete）')
                .fontSize(11)
                .fontColor($r('app.color.font_tertiary'))
                .width('100%')

              TextArea({ text: this.scriptInput, placeholder: '(async () => { __complete(await nativeFetch("x")) })()' })
                .fontSize(12)
                .fontFamily('monospace')
                .height(96)
                .width('100%')
                .backgroundColor($r('app.color.bg_page'))
                .borderRadius(10)
                .onChange((v: string) => {
                  this.scriptInput = v;
                })

              Button('运行自定义脚本')
                .width('100%')
                .backgroundColor($r('app.color.emphasize_bg_light'))
                .fontColor($r('app.color.brand'))
                .fontSize(14)
                .enabled(!this.running)
                .onClick(() => {
                  this.runTest();
                })
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            // ── 结果输出 ──
            Column() {
              Text('输出')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
                .margin({ left: 4, bottom: 8 })

              Text(this.resultText)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor($r('app.color.font_primary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(12)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            Text('native 模块：libpluginhost.so · JSVM(ark_runtime) · 结果同步回传 ArkTS Promise')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
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
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
