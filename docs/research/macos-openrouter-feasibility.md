# macOS 萌宠与 OpenRouter：首版技术可行性

Swift 原生应用是本项目值得优先验证的路线：首版只服务用户自己的 Mac，已确认的需求是一个可拖动、无声、不主动观察电脑的小宠物，而非跨平台网页或电脑操作 Agent。这个建议尚未得到用户确认；现有官方资料说明相关窗口和聊天能力可用，但不能证明应用已经达到 CPU 或内存预算。

查证日期：2026-11-14。作者：Manus AI。

## 原生窗口可以承载角色，桌面细节仍须验证

Apple 将 `NSPanel` 定义为通常执行辅助功能的特殊窗口，并提供浮动面板与按需成为键盘焦点窗口的属性。[1] `nonactivatingPanel` 的明确含义是不激活所属应用的面板。[2] 因此可以将平时展示角色的面板与需要用户输入的聊天窗口分开设计，避免聊天输入逻辑污染宠物常驻行为。

这不代表加上一个属性就能保证所有情况下完全不影响焦点。抚摸、右键菜单、聊天输入和拖动的焦点规则仍须逐项验证。

`NSWindow.isOpaque` 可以声明窗口是否不透明，官方也提供背景色相关属性。[3] 这支持透明角色窗口的实现方向，但文档没有说明透明像素就一定会把鼠标事件交给下方应用。点击命中区域和透明区域穿透必须成为原型的独立验收项。

Apple 的 `CollectionBehavior` 区分普通 Spaces 与全屏行为：`canJoinAllSpaces` 允许窗口出现在所有空间；`fullScreenAuxiliary` 使窗口出现在全屏窗口所在的空间。[4] 所以“陪用户切换普通桌面”和“覆盖其他应用的全屏空间”是需要单独决定、测试的两件事，不应把前者直接当作后者的保证。还应检查本机 macOS 15.6 的可用 API，不能照搬最新文档中所有符号。

本机检查已确认 arm64、macOS 15.6、16 GiB 内存以及可用的 Swift 6.2.1 / Xcode 工具链。这只是环境证据，尚未构建或运行应用。建议首先验证透明面板、拖动、焦点和资源，再完善角色动作。

## OpenRouter 可以直接承载显式文字聊天

OpenRouter 官方聊天接口支持流式与非流式请求，生产服务地址为 `https://openrouter.ai/api/v1`，聊天路径为 `/chat/completions`。请求包含 `model` 和 `messages`，并可限制输出 token 数量。[5] 对首版来说，不需要为了调用模型搭建自有云端服务；这是根据个人本机应用目标作出的架构建议，并不是已实现的网络模块。

官方认证使用 Bearer token，API key 可配置额度限制。OpenRouter 建议为密钥设置额度，并避免将密钥提交到公开仓库。[7] Apple Keychain 服务提供加密数据库来安全存储小型秘密。[8] 因此建议在本机设置界面填写自己的 key，并用本机 Keychain 保存，不把 key 写入项目文档、源代码或日志；具体 Keychain 访问策略和非同步设置仍须实现时明确。

模型 ID 建议先由用户配置，不在设计阶段固定具体型号或承诺费用。模型价格、可用性、供应商路由与数据政策应在选择模型时核对，当前没有调用付费接口。

## 流式反馈可以改善等待体验，但不能掩盖错误或费用

OpenRouter 流式输出使用 SSE，可能发送以冒号开头的保活注释。手写解析器不能把这些注释当作 JSON。[6] 聊天流还可能带最终 usage 帧，终止原因可能重复；显示文字、完成状态和费用统计应分别处理。[6]

请求开始前的失败可以是带 HTTP 状态的 JSON 错误；响应头已发送后，失败可能出现在 HTTP 200 的流内错误事件中。[6] 所以成功不能仅由 HTTP 200 判定，也不能把连接中断显示成完整回答。首版应保留输入与已生成内容，显示清楚的错误，并让用户决定是否重试。

关闭连接可以取消流式请求，但能否停止模型处理与后续计费取决于供应商是否支持。官方明确指出不支持取消的供应商，以及非流式请求，仍可能生成并计费。[6] 应避免承诺“点停止就绝对不再花钱”。设置输出上限、限制同时请求数、采用 OpenRouter key 的额度限制，比依赖取消更可靠；这些是待确认的产品建议。

CPU 平均低于 1% 和驻留内存不超过 100 MB 仍是目标。需要在角色静置、短动画、拖动、流式聊天与长时间驻留等不同场景测量，文档查证不能代替实测。

## References

[1]: https://developer.apple.com/documentation/appkit/nspanel "Apple NSPanel"
[2]: https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel "Apple nonactivatingPanel"
[3]: https://developer.apple.com/documentation/appkit/nswindow/isopaque "Apple NSWindow isOpaque"
[4]: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct "Apple NSWindow CollectionBehavior"
[5]: https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion "OpenRouter Create a chat completion"
[6]: https://openrouter.ai/docs/api_reference/streaming "OpenRouter Streaming"
[7]: https://openrouter.ai/docs/api_reference/authentication "OpenRouter Authentication"
[8]: https://developer.apple.com/documentation/security/keychain-services "Apple Keychain services"
