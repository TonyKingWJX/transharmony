/**
 * 「我的」页二级页（NavDestination）：
 * - PrivacyPage：隐私政策——按华为应用市场《隐私政策链接提交及内容规范参考FAQ》官方模板撰写，
 *   分章节（收集使用/权限/共享/存储保护/用户权利/未成年人/更新/联系），
 *   敏感个人信息段落加粗突出展示。
 *   首启的标准隐私弹窗由系统自动弹出，应用内不得自绘隐私同意弹窗（否则上架审核驳回）。
 * - AboutPage：应用信息卡 + 更新内容（版本历史，新版本在上）；用户反馈交流入口已上移至设置页「关于」卡
 *   连点应用信息卡 5 次（2 秒内）弹窗确认后开启开发者模式：卡下方出现「开发者模式」行（开关 + 二级页入口），
 *   开关关闭后入口隐藏、日志系统同步停采并清空
 * - FeedbackPage：用户反馈交流 QQ 群（群号可复制 + 群二维码）
 * 沉浸式与自定义标题栏样式与其他 NavDestination 页保持一致。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { settingsStore } from '../services/SettingsStore';
import { devLogStore } from '../services/DevLogStore';

export const APP_VERSION: string = 'v1.0.4';

/** 开发者/运营者名称：须与 AppGallery Connect 上提交的开发者名称保持一致（审核要求） */
export const DEVELOPER_NAME: string = '鸿译开发团队';
/** 隐私政策生效日期 */
const POLICY_EFFECTIVE_DATE: string = '2026年09月11日';

interface UpdateEntry {
  version: string;
  date: string;
  current: boolean;
  items: string[];
}

const UPDATE_LOG: UpdateEntry[] = [
  {
    version: 'v1.0.4',
    date: '2026-09-15',
    current: true,
    items: [
      '新增 AI 服务商：小米 MiMo、OpenAI 官方，均为 OpenAI 兼容协议官方预置',
      '「OpenAI 兼容服务」「Anthropic 兼容服务」配置页不再显示官方 Key 获取链接（兼容服务的 Key 请向服务提供方获取）'
    ]
  },
  {
    version: 'v1.0.3',
    date: '2026-09-14',
    current: false,
    items: [
      '新增语言：内置印尼语、德顿语；语言选择器支持插件声明的扩展语言（粤语、文言文等）',
      '新增插件备份：备份可选携带已安装插件（含配置与密钥），换机恢复免重新导入',
      '备份密码改为可选：不设密码即可快速备份，恢复时自动识别、免输密码'
    ]
  },
  {
    version: 'v1.0.2',
    date: '2026-09-13',
    current: false,
    items: [
      '新增 manggo 插件支持：导入 .mplugin 即装即用，翻译 / 文字识别 OCR / 语音 TTS 全覆盖',
      '多服务插件：一个插件包含多个服务（如多个翻译引擎、翻译+OCR），配置页统一勾选启用、逐服务独立配置',
      '插件服务自主可控：多服务插件默认不铺满主页，勾选哪些显示哪些，未勾选的不参与聚合',
      'manggo 插件沙盒：ES Module 自动转换、fetch 流式（SSE）、常用哈希、语言码自动映射、词典结果展开',
      '稳定性：修复插件重载可能引发的闪退；引擎卡死自动中断并提示，切换引擎即刻恢复翻译',
      '界面修复：输入框光标顶部被裁切的问题'
    ]
  },
  {
    version: 'v1.0.1',
    date: '2026-09-12',
    current: false,
    items: [
      '新增插件系统：从文件管理器导入 .bobplugin 翻译插件，即装即用',
      '插件即引擎：自动出现在主页引擎行，支持拖拽排序、开关与删除',
      '插件服务管理页：我的 → 翻译服务 → 插件服务 统一管理',
      '聚合翻译支持插件参与并发，结果逐个返回',
      '插件在本机沙盒内运行：JS 隔离执行，网络经应用统一发起，密钥仅存本机',
      '内置 CommonJS 多文件模块与 crypto-js，兼容主流翻译插件',
      '支持词典型插件结果：查词展示词头、音标与词性释义',
      '修复冷启动时引擎列表偶发显示异常'
    ]
  },
  {
    version: 'v1.0.0',
    date: '2026-09-11',
    current: false,
    items: [
      '聚合翻译：并发所有已配置引擎，结果逐个返回，一键采用',
      '自定义服务商 BYOK：腾讯云、阿里云、百度、Azure、彩云、小牛等',
      'AI 翻译：OpenAI 兼容（DeepSeek/GLM/通义/Kimi）与 Anthropic 协议，自动获取模型列表',
      '自定义翻译 Prompt：翻译风格、术语可自行调教',
      '语音输入：识别暂停/继续，识别完成自动翻译',
      '拍照翻译：端侧识别文字，照片默认用后即删，可选保存到相册',
      '译文朗读：支持暂停/继续，不支持的语言自动置灰提示',
      '历史记录新增回收站：删除的记录保留 30 天，可恢复或彻底删除',
      '历史记录新增详情页，支持多选批量删除',
      '添加服务商面板改为半模态：返回键即可关闭，层级更合理',
      '凭证加密存储：服务商密钥迁移至系统关键资产库，不再明文保存',
      '修复页签切换、批量删除、面板再次弹出等一批真机问题',
      '连通测试：填好凭证一键验证可用性',
      '深色模式全面适配，悬浮胶囊页签，沉浸式界面'
    ]
  },
  {
    version: 'v0.2.0',
    date: '2026-09-09',
    current: false,
    items: [
      '新增自定义翻译 Prompt 与服务连通测试',
      '深色模式适配：开屏、添加面板状态栏沉浸式优化',
      '修复若干界面显示问题'
    ]
  },
  {
    version: 'v0.1.0',
    date: '2026-09-04',
    current: false,
    items: [
      '首个版本：聚合并发多引擎翻译，结果逐个返回',
      '历史记录：搜索、收藏、语言对筛选、长按删除',
      '悬浮胶囊页签与深浅色主题'
    ]
  }
];

/** 隐私政策段落：sensitive 为敏感个人信息相关内容，渲染时加粗突出展示（审核要求 7.1 合规要求3） */
interface PrivacyPara {
  text: string;
  sensitive: boolean;
}

/** 隐私政策章节：结构大纲参照华为应用市场《隐私政策参考范本》（个人信息安全规范 附录D） */
interface PrivacySection {
  title: string;
  paras: PrivacyPara[];
}

const PRIVACY_INTRO: string =
  '《鸿译 TransHarmony 隐私政策》（下称"本政策"）帮助您了解我们处理您个人信息的目的、方式、范围，以及您如何行使您的权利。' +
  '使用本应用前，请务必仔细阅读并充分理解本政策，特别是加粗的条款。您点击翻译、开启语音输入等行为，即表示您已阅读并同意本政策。';

const PRIVACY_SECTIONS: PrivacySection[] = [
  {
    title: '一、我们如何收集和使用您的个人信息',
    paras: [
      {
        text: '我们仅为实现翻译及相关功能处理您的个人信息，遵循合法、正当、必要与最小化原则。本应用无需注册或登录，不收集您的手机号码、位置信息、通讯录、软件安装列表等与功能无关的个人信息。',
        sensitive: false
      },
      {
        text: '（一）文本翻译。当您输入或粘贴文本并点击翻译时，本应用将您输入的文本通过网络请求发送至您选择或配置的翻译服务商，以获取译文。若您启用多个服务商进行聚合翻译，同一段文本将并发发送至各已启用服务商以汇总结果。',
        sensitive: false
      },
      {
        text: '（二）语音输入。当您点击「语音」按钮并授权麦克风权限后，本应用使用设备端语音识别服务将您的语音实时转换为文字用于翻译。语音识别在本设备端完成，您的录音不会上传至本应用或任何第三方服务器，识别后不留存音频。麦克风权限用于收集录音，属于敏感权限；您可以拒绝授权，拒绝后仅语音输入功能不可用，其余功能不受影响，您也可以随时在系统设置中关闭该权限。',
        sensitive: true
      },
      {
        text: '（三）拍照翻译。当您点击「拍照」时，本应用通过系统拍照服务获取您拍摄的照片，并使用设备端文字识别技术提取图中文字用于翻译；从相册选择图片时同样在设备端完成识别。照片与识别过程均在本设备完成，不会上传至任何服务器；除您主动开启「拍照后提供保存到相册」并点击保存外，照片用后即删。相机拍摄的照片可能包含您的面部、住址等敏感个人信息，请您自行把握拍摄内容。',
        sensitive: true
      },
      {
        text: '（四）译文朗读。当您点击朗读按钮时，本应用使用设备端语音合成服务朗读译文，不涉及网络上传与个人信息收集。',
        sensitive: false
      },
      {
        text: '（五）网络与连通测试。本应用使用网络权限访问翻译服务商接口；当您使用「连通测试」或选择 AI 模型时，会向您配置的服务商发起请求以验证凭证有效性或获取模型列表。',
        sensitive: false
      },
      {
        text: '（六）历史记录与偏好设置。为提供历史记录、收藏与搜索功能，本应用在本机保存您的翻译文本记录；您的服务商凭证、语言与界面偏好等设置同样仅保存在本机。您可以随时在应用内删除历史记录，卸载应用将一并删除上述全部数据。',
        sensitive: false
      },
      {
        text: '（七）复制功能。当您点击「复制」按钮时，本应用将译文、群号等内容写入设备剪切板供您粘贴使用；本应用不会在后台读取您的剪切板内容。',
        sensitive: false
      },
      {
        text: '（八）用户反馈交流。当您加入用户群或通过应用市场评论区反馈时，您主动提供的信息（如截图、问题描述）由对应平台按其规则处理，本应用不主动收集。',
        sensitive: false
      }
    ]
  },
  {
    title: '二、我们如何调用设备权限',
    paras: [
      {
        text: '为实现上述功能，本应用申请以下设备权限，均仅在您使用对应功能时使用，您可以在系统设置中随时开启或关闭：网络权限（INTERNET、GET_NETWORK_INFO），用于访问翻译服务商接口并获取网络状态以提示错误；麦克风权限（MICROPHONE），用于语音输入识别。',
        sensitive: false
      },
      {
        text: '本应用不申请位置、通讯录、短信、日历、存储等权限：拍照通过系统拍照服务完成，相册选图通过系统图库选择器完成，保存图片通过系统安全控件临时授权完成，均无需另行授权。',
        sensitive: false
      }
    ]
  },
  {
    title: '三、我们如何共享您的个人信息',
    paras: [
      {
        text: '本应用不向任何第三方出售您的个人信息，也不嵌入任何第三方统计、广告 SDK。仅当您主动发起翻译或连通测试时，本应用才将您当次输入的文本（或用于验证的凭证信息）通过网络直接发送给您选择的服务商：',
        sensitive: false
      },
      {
        text: '免费通道：微软翻译、有道翻译；您自行配置的服务商：腾讯云、阿里云、百度翻译、Azure、彩云科技、小牛翻译等；AI 服务商：DeepSeek、智谱 GLM、通义千问、Kimi、小米 MiMo、OpenAI、Anthropic 等兼容 OpenAI 或 Anthropic 协议的服务商。',
        sensitive: false
      },
      {
        text: '上述服务商按其各自公布的隐私政策处理相关数据，建议您在配置前阅读对应服务商的隐私政策。除此之外，本应用不会共享、转让、公开披露您的任何个人信息。',
        sensitive: false
      }
    ]
  },
  {
    title: '四、我们如何存储和保护您的个人信息',
    paras: [
      {
        text: '您的全部数据（翻译历史、收藏、服务商凭证、偏好设置）均存储在设备本地，本应用不搭建服务器，不在云端存储您的任何数据；服务商凭证将采用系统加密存储能力保护。卸载本应用即删除上述全部数据。',
        sensitive: false
      },
      {
        text: '传输方面，我们通过 HTTPS 等加密方式与服务商通信；语音识别与文字识别均在设备端完成，最大限度减少个人信息流动。照片在识别完成后立即删除，或按您的选择仅保存至本机相册。',
        sensitive: false
      }
    ]
  },
  {
    title: '五、您的权利',
    paras: [
      {
        text: '按照相关法律法规，您对自己的个人信息享有查阅、复制、更正、删除等权利：您可以在应用内随时查看与修改服务商配置和偏好设置；可以删除单条或全部历史记录；拍照照片默认用后即删。',
        sensitive: false
      },
      {
        text: '您可以撤回同意：在系统设置中关闭麦克风等权限即视为撤回对应授权；卸载本应用即撤回全部授权并删除全部数据。本应用不提供账号注册功能，不存在账号注销事项。',
        sensitive: false
      },
      {
        text: '如对个人信息保护有疑问或投诉，请通过「用户反馈交流」加入用户群或通过应用市场评论区联系我们，我们将在十五个工作日内答复处理。',
        sensitive: false
      }
    ]
  },
  {
    title: '六、我们如何处理未成年人的个人信息',
    paras: [
      {
        text: '本应用为通用翻译工具，不会主动收集未成年人的个人信息。若您是未满十四周岁的未成年人，请在监护人陪同下阅读本政策，并在征得监护人同意后使用本应用。',
        sensitive: false
      }
    ]
  },
  {
    title: '七、本政策如何更新',
    paras: [
      {
        text: '我们可能适时更新本政策，未经您明确同意不会削减您依照本政策享有的权利。发生重大变更时（如处理个人信息的目的、方式、范围变化，对外提供个人信息的方式变化，或您权利及其行使方式变化），我们会在应用内显著位置公告或弹窗提示。',
        sensitive: false
      }
    ]
  },
  {
    title: '八、如何联系我们',
    paras: [
      {
        text: '开发者/运营者：' + DEVELOPER_NAME + '。如您对本政策或个人信息保护有任何疑问、意见或建议，可通过「用户反馈交流」页加入用户群，或通过应用市场评论区留言，我们将在十五个工作日内答复。',
        sensitive: false
      },
      {
        text: '如果您对我们的回复不满意，特别是认为我们的个人信息处理行为损害了您的合法权益，您还可以向网信部门或其他主管部门投诉、举报。',
        sensitive: false
      }
    ]
  }
];

@Component
export struct PrivacyPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
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

          Text('隐私政策')
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
            // ── 政策标题与生效信息 ──
            Column({ space: 4 }) {
              Text('鸿译 TransHarmony 隐私政策')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.font_primary'))
                .textAlign(TextAlign.Center)
              Text('生效日期：' + POLICY_EFFECTIVE_DATE + ' · 开发者/运营者：' + DEVELOPER_NAME)
                .fontSize(11)
                .fontColor($r('app.color.font_tertiary'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            // ── 隐私政策正文（分章节，敏感个人信息段落加粗突出展示） ──
            Column({ space: 14 }) {
              Text(PRIVACY_INTRO)
                .fontSize(13)
                .lineHeight(22)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
              ForEach(PRIVACY_SECTIONS, (sec: PrivacySection, sIdx: number) => {
                Column({ space: 8 }) {
                  Text(sec.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.font_primary'))
                    .width('100%')
                  ForEach(sec.paras, (p: PrivacyPara, pIdx: number) => {
                    Text(p.text)
                      .fontSize(13)
                      .lineHeight(22)
                      .fontWeight(p.sensitive ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor($r('app.color.font_secondary'))
                      .width('100%')
                  }, (p: PrivacyPara, pIdx: number) => sIdx + '-' + pIdx)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (sec: PrivacySection) => sec.title)
            }
            .width('100%')
            .padding(16)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Start)

            Text('如有隐私相关问题，欢迎通过「用户反馈交流」群或应用市场评论区联系我们。')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 4, bottom: 30 + this.navBarH })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}

const QQ_GROUP_NAME: string = '鸿译用户交流反馈群';
const QQ_GROUP_NUMBER: string = '1124439059';

/** 用户反馈交流页：QQ 群号（可复制）+ 群二维码 */
@Component
export struct FeedbackPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private copyGroupNumber(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, QQ_GROUP_NUMBER);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('群号已复制');
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

          Text('用户反馈交流')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 14 }) {
            // ── 群信息卡 ──
            Column({ space: 14 }) {
              Row({ space: 12 }) {
                // 群头像
                Stack() {
                  Circle()
                    .width(52)
                    .height(52)
                    .fill($r('app.color.brand'))
                  SymbolGlyph($r('sys.symbol.message'))
                    .fontSize(24)
                    .fontColor([$r('sys.color.ohos_id_color_text_primary_contrary')])
                }
                .width(52)
                .height(52)

                Column({ space: 4 }) {
                  Text(QQ_GROUP_NAME)
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.font_primary'))
                  Row({ space: 8 }) {
                    Text('群号：' + QQ_GROUP_NUMBER)
                      .fontSize(13)
                      .fontColor($r('app.color.font_secondary'))
                    Text('复制')
                      .fontSize(11)
                      .fontColor($r('app.color.brand'))
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .borderRadius(999)
                      .backgroundColor($r('app.color.emphasize_bg_light'))
                      .onClick(() => {
                        this.copyGroupNumber();
                      })
                  }
                  .alignItems(VerticalAlign.Center)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Divider()
                .color($r('app.color.divider'))
                .strokeWidth(0.8)

              // 群二维码
              Image($r('app.media.qq_group_qrcode'))
                .width('86%')
                .borderRadius(16)
                .border({ width: 0.8, color: $r('app.color.divider') })
                .objectFit(ImageFit.Contain)

              Text('扫一扫二维码，加入群聊')
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
            }
            .width('100%')
            .padding(18)
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Center)

            Text('反馈问题时请尽量附上截图与操作步骤，我们会尽快处理。')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ bottom: 30 + this.navBarH })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}

@Component
export struct AboutPage {
  @Consume('navPathStack') pathStack: NavPathStack;
  @StorageProp('ux_statusBarH') statusBarH: number = 0;
  @StorageProp('ux_navBarH') navBarH: number = 0;
  /** 开发者模式开关（EntryAbility 启动时写入 AppStorage，经 @StorageLink 跨页同步 + 持久化） */
  @StorageLink('dev_mode') devMode: boolean = false;
  /** 连点计数：2 秒窗口内累计应用信息卡点击次数 */
  private tapCount: number = 0;
  private lastTapAt: number = 0;

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 连点应用信息卡：2 秒内累计 5 次触发确认弹窗；已开启时提示不重复弹 */
  private onLogoTap(): void {
    const now = Date.now();
    this.tapCount = now - this.lastTapAt <= 2000 ? this.tapCount + 1 : 1;
    this.lastTapAt = now;
    if (this.tapCount < 5) {
      return;
    }
    this.tapCount = 0;
    if (this.devMode) {
      this.toast('开发者模式已开启');
      return;
    }
    this.confirmDevMode();
  }

  /** 开发者模式确认弹窗：打开 → 出现开发者模式行与开关；取消 → 画面无变化 */
  private confirmDevMode(): void {
    this.getUIContext().showAlertDialog({
      title: '打开开发者模式？',
      message: '开发者模式包含插件实验室、日志系统等调试功能，仅供开发调试使用。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '打开',
        fontColor: $r('app.color.brand'),
        action: (): void => {
          this.devMode = true;
          settingsStore.setDevMode(true);
          this.toast('您已打开开发者模式');
        }
      },
      secondaryButton: {
        value: '取消',
        fontColor: $r('app.color.font_secondary'),
        action: (): void => {
          // 画面无变化，开发者模式保持默认关闭与隐藏
        }
      }
    });
  }

  /** 开关联动：关闭时入口隐藏，日志系统同步停采并清空 */
  private onDevModeToggle(on: boolean): void {
    this.devMode = on;
    settingsStore.setDevMode(on);
    if (!on) {
      devLogStore.disable();
    }
  }

  @Builder
  logEntry(e: UpdateEntry) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(e.version)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(e.current ? $r('app.color.brand') : $r('app.color.font_primary'))
        if (e.current) {
          Text('当前版本')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
            .backgroundColor($r('app.color.emphasize_bg_light'))
            .borderRadius(999)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
        Blank()
        Text(e.date)
          .fontSize(11)
          .fontColor($r('app.color.font_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 5 }) {
        ForEach(e.items, (it: string) => {
          Row({ space: 8 }) {
            Circle()
              .width(4)
              .height(4)
              .fill($r('app.color.font_tertiary'))
              .margin({ top: 8 })
            Text(it)
              .fontSize(13)
              .lineHeight(19)
              .fontColor($r('app.color.font_secondary'))
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (it: string) => e.version + it)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('app.color.card_bg'))
    .border({ width: 0.8, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
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

          Text('关于鸿译')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 14 }) {
            // ── 应用信息卡 ──
            Column({ space: 6 }) {
              Image($r('app.media.start_icon'))
                .width(84)
                .height(84)
                .margin({ bottom: 6 })
              Text('鸿译 TransHarmony')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.font_primary'))
              Text('给鸿蒙用户的翻译瑞士军刀')
                .fontSize(12)
                .fontColor($r('app.color.font_tertiary'))
              Text(APP_VERSION)
                .fontSize(11)
                .fontColor($r('app.color.brand'))
                .padding({ top: 2 })
            }
            .width('100%')
            .padding({ top: 22, bottom: 20 })
            .borderRadius(16)
            .backgroundColor($r('app.color.card_bg'))
            .border({ width: 0.8, color: $r('app.color.divider') })
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.onLogoTap();
            })

            // ── 开发者模式（连点图标开启后显示；开关关闭即隐藏） ──
            if (this.devMode) {
              Column() {
                Row({ space: 12 }) {
                  Column({ space: 3 }) {
                    Text('开发者模式')
                      .fontSize(15)
                      .fontColor($r('app.color.font_primary'))
                    Text('插件实验室 · 日志系统（开发调试）')
                      .fontSize(11)
                      .fontColor($r('app.color.font_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Toggle({ type: ToggleType.Switch, isOn: this.devMode })
                    .width(40)
                    .height(24)
                    .selectedColor($r('app.color.brand'))
                    .onChange((on: boolean) => {
                      this.onDevModeToggle(on);
                    })

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(14)
                    .fontColor([$r('app.color.font_fourth')])
                }
                .width('100%')
                .padding({ top: 13, bottom: 13 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.pathStack.pushPath({ name: 'DeveloperPage' });
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .borderRadius(16)
              .backgroundColor($r('app.color.card_bg'))
              .border({ width: 0.8, color: $r('app.color.divider') })
            }

            // ── 更新内容 ──
            Column({ space: 8 }) {
              Text('更新内容')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_secondary'))
                .letterSpacing(1)
                .width('100%')
                .margin({ left: 4 })

              ForEach(UPDATE_LOG, (e: UpdateEntry) => {
                this.logEntry(e)
              }, (e: UpdateEntry) => e.version)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Text('HarmonyOS NEXT · ArkTS 原生开发')
              .fontSize(11)
              .fontColor($r('app.color.font_fourth'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ bottom: 30 + this.navBarH })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.bg_page'))
  }
}
