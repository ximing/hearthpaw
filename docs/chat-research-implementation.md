# 0.2.0 聊天与调研接入记录

2026-11-14。用户已明确授权从模型配置升级到聊天和资料调研调用。实现沿用Swift6/AppKit，不引入WebView、Node、Python服务、远程桌面或第三方运行时依赖。

## 模块边界

`AgentTypes` 固定请求、真实工具轨迹、会话和任务类型；`OpenRouterClient` 隐藏HTTP、认证头、流式SSE与Responses格式。请求固定官方HTTPS地址，ephemeral session无持久cookie/cache，拒绝重定向，无自动重试或模型替换。请求256KiB、响应2MiB、文本40000字符有边界；网络异步，不阻塞主线程。仅最终response.completed是真成功，delta仅用于显示；断流、error、incomplete、length与HTTP错误都失败且脱敏。

`AgentCoordinator` 管陪伴上下文与本地派工。最新20条/6000字符仅保留成功会话，当前输入过长拒绝、不静默丢弃；失败片段可见但不参与后续历史。陪伴单请求获得登记的delegate_research函数，当前明确委派、逐字引用、动作数量/名称/参数和否定语句经本地校验后执行。工作只收到当前提交文本而非模型从私人历史推导的topic，因此不泄露私人历史或persona。最多一个工作任务，聊天可并行。锁屏/休眠/退出请求取消，不自动重发。

`ResearchWorker` 一次搜索/读取收集，第二次工具关闭写作；整个任务3search/5fetch/8工具调用、最多2客户端请求、5分钟超时。用真实output trace和服务器usage核对总预算，不把缺统计当零、不重置预算。仅completed且非空正文、非HTTP错误的FetchedPage成为证据，每篇6000字符、合计24000字符。写作只用JSON证据，校验[S1]等引用与链接集合，再由客户端附加真实URL。网页/标题/模型文本不能新增工具或写入权限。

`ResearchTaskStore` 把UUID任务目录和固定task.json/report.md/draft.md封装在openat/O_NOFOLLOW目录描述符后，0700目录、0600文件、fsync和原子提交，阻止符号链接、硬链接、越界和报告覆盖。只有真实完整报告文件存在才允许完成；草稿有独立查找入口，不能被当作完整报告。元信息损坏跳过并提示，重启把旧运行任务标为中断，不自动恢复模型请求。

`ChatWindowController` 用原生纯文本控件展示，不执行Markdown或网页脚本。输入/明确调研按钮、独立取消、历史、报告/草稿打开/Finder/另存为、清会话和设置均显式操作。120ms按事件合并渲染，只替换变化后缀，无常驻轮询。另存为UTF8 Markdown使用排他创建，不覆盖已有目标。新增“取回上条输入”只把当前运行中上一条用户文本放回空编辑器，不自动发请求或覆盖新草稿。

模型和外观持久化增加可编辑personaPrompt，旧JSON向后兼容；人格6000字符、trim、空白回默认。角色只影响下一次陪伴请求，不改变权限，不影响已启动工作。Keychain启动不读secret，状态查询静默，用户明确发送/保存/删除时允许macOS处理升级签名导致的授权；不会明文回退。

## 实测

- Release0.2.0原生构建与本机ad-hoc签名检查通过。仅AppIntents元数据无依赖的常规跳过提示，没有Swift编译错误。
- 最终统一XCTest **102项、0失败**：配置16、密钥纯校验4、上下文/路由2、网络24、协调器6、几何10、分区6、任务存储15、调研19。离线模拟，不调用真实OpenRouter。
- 原生设置、窗口和宠物状态85项，动画时序21项，合成陪伴→自动派工→真实Markdown文件→历史重载→聊天窗口28项全部通过。设置/聊天图片来自自身视图绘制，不读取用户屏幕。
- 随机隔离Keychain服务14项通过：缺失/保存/读取/更新/删除/本地后端。只使用合成值，完成清理，不读取生产项、不输出secret。
- 网络URLProtocol模拟包括拆分中文UTF8、多行SSE、注释/BOM/CRLF、HTTP402、error/failed/incomplete、提前EOF、最终输出权威、真实工具轨迹、跨域跳转不发第二请求、取消触发底层stopLoading，以及错误/用量/预算处理。

首次统一测试中，调研测试fixture的系统临时URL经macOS别名呈现为/var，触发严格的禁止跟随symlink检查。父协调器使用项目内scratch的相同工作链路通过，据此将两组测试fixture统一放在项目.work中；未放宽生产路径安全。原有越界、根/UUID/file symlink与hardlink测试继续通过。整合时还修复了“界面显示草稿按钮，但完整报告查找入口不返回草稿”的接线缺口，并新增草稿查找symlink回归。

## 尚未验证/实现

没有使用真实用户key或付费模型联调，不能据mock通过保证任何模型兼容OpenRouter Beta工具。用户首次显式发送时检验key、余额、模型和服务器能力；错误不自动重试。无新版完整30分钟CPU/RSS、GPU/能耗归因或真人跨应用/多物理屏幕完整验收，不移用旧版性能数字。

长期记忆索引和正文、记忆治理、亲密度/养成计分、主动招呼未接入。聊天不持久化；研究报告和元信息持久化。store:false不是远端供应商和工具零留存保证。最终用户说明见outputs/agent-020/Chat-Research-Delivery.md，接口查证见docs/research/openrouter-agent-integration.md。
