# 聊天与调研的接口落点

2026-11-14，Manus AI。此次实施使用 OpenRouter Responses API，固定 `https://openrouter.ai/api/v1/responses`，每次包含完整受限上下文、`store:false`，不使用 previous_response_id。官方说明该代理仅支持无状态请求，store:true 与非空 previous_response_id 会被拒绝。[1]

流式成功以 `response.completed` 的最终 response 为准。`response.output_text.delta` 用于界面更新；`response.failed`、`response.incomplete` 或 error 都不能因 HTTP200 变成成功。跳过 SSE 注释，正确处理多行 data、UTF8、提前断流和取消。断开客户端不保证所有供应商立即停止生成或计费。[2]

陪伴模型只获得客户端函数 `delegate_research`，函数是建议，由本地登记能力和当前用户明确指令校验后派工；不赋予 shell、任意文件或其他工具权限。普通函数必须由客户端执行，不是模型输出工具名就完成。[3]

调研模型第一次请求可使用固定 Exa 搜索与 OpenRouter 正文抓取，分别限制三次和五次，max_tool_calls8；不依赖 native 引擎可能忽略的限制。第二次没有网络工具，只使用已经实际读取的来源正文写报告。每任务两次客户端模型请求，低于已同意的三次上限；这不等于远端内部总调用次数或美元硬上限。Exa与模型token可能额外计费，工具仍处Beta，不兼容要显式失败，不静默切换路线。[4] [5] [6]

完整官方 schema 的 `output` 项目可携带 `type:openrouter:web_search` 的 action/query/sources/status，以及 `type:openrouter:web_fetch` 的 url/title/content/httpStatus/retrieved_at/status。仅 `status:completed` 且非空 content 的抓取项是应用接受的已读来源；模型在普通文本里列出的来源不算工具证据。对应 schema 定义已保存在任务工作目录用于实现与测试。[7]

报告文件由 Mac 应用在自身任务目录原子写入，不是服务器工具替用户写本地文件。完成状态必须以真实文件和元信息成功保存为前提。网页与来源正文被当作不可信资料，不能改变执行权限。实现结果、mock覆盖与尚未实际付费联调的边界另外记录，本文不把接口文档当作实测。

## References

[1]: https://openrouter.ai/docs/api_reference/responses/overview "OpenRouter stateless Responses API"
[2]: https://openrouter.ai/docs/api_reference/streaming "OpenRouter streaming and cancellation"
[3]: https://openrouter.ai/docs/guides/features/tool-calling "OpenRouter client tools"
[4]: https://openrouter.ai/docs/guides/features/server-tools "OpenRouter server tools and budgets"
[5]: https://openrouter.ai/docs/guides/features/server-tools/web-search "OpenRouter server web search"
[6]: https://openrouter.ai/docs/guides/features/server-tools/web-fetch "OpenRouter server web fetch"
[7]: https://openrouter.ai/docs/api/api-reference/responses/create-responses "OpenRouter Responses request and output schemas"
