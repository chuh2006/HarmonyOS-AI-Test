`chat/` 是你的工作目录是一个 HarmonyOS ArkTS 示例项目。请在当前项目中实现一个完整的 HarmonyOS 手机 AI 聊天 APP，可直接在 DevEco Studio 编译和运行。

## 一、基本功能

接入 DeepSeek、Inception Mercury 和 Google Gemini 三家官方 API，支持：

- 选择服务商和模型，分别填写、保存 API Key。
- 多轮对话、实时流式输出、停止生成，以及失败后的重试。
- 思考内容或思考摘要与回答正文分别展示，思考区域可折叠。
- 新建、切换、删除会话，保存并读取历史记录；重启 APP 后能继续原会话。
- 真正可用的工具调用：实现 `search`、`fetch` 工具，使用 DeepsSeek 提供的网页搜索与抓取接口。
- 清晰展示请求中、思考中、工具执行中、回答中、完成、已停止和失败等状态。
- 前端界面简洁、精致、美观、有设计感，适合普通用户使用；要让用户意识到这是一个精心制作的 APP 而不是粗制滥造的 AI 垃圾。
- 不得将功能堆满主界面，不要把任务要求写在前端。

各服务商的模型能力和参数需要分别适配，界面只显示当前模型实际支持的选项。

## 二、DeepSeek

对话使用官方 Responses API：

- 地址：`https://api.deepseek.com/responses`
- 模型：`deepseek-flash`、`deepseek-v4-pro`。
- 必须使用流式请求，实时展示 `reasoning_content` 和 `content`。
- 支持开启、关闭思考，开启后可选 `low`、`high`、`max`，`none` 表示关闭思考。
- 按官方要求正确保存和回传所需的思考内容。

开启思考的请求体示意：

```json
{
  "model": "deepseek-flash",
  "input": "你好",
  "reasoning": {
    "effort": "none"
  },
  "stream": true
}
```

Search 接口和 Fetch 接口使用官方 v1/tools API：

- Search 接口按 query 搜索网页，返回结构化结果。该接口由 DeepSeek 自研搜索引擎提供支持。
- Fetch 接口抓取单个网页，以 Markdown 文本返回页面内容。

两者都是原始 JSON API，使用与 DeepSeek API 相同的 Bearer 鉴权。

| API | Endpoint |
| --- | -------- |
| Search | `https://api.deepseek.com/v1/tools/search` |
| Fetch | `https://api.deepseek.com/v1/tools/fetch` |

请求体示意：

Search：

```json
{
  "query": "DeepSeek V4 模型 发布",
  "count": 5,
  "need_content": true
}
```

Fetch：

```json
{
  "url": "https://example.com/article"
}
```

分别向用户和模型展示适合彼此的内容，不要把完整搜索结果或摘要展示给用户，这是对话 APP 不是搜索引擎，即便是搜索引擎也不会把结果全部一次性展示。

## 三、Inception Mercury

使用官方 Chat Completions API：

- 地址：`https://api.inceptionlabs.ai/v1/chat/completions`
- 模型：`mercury-3`。
- 支持普通流式输出和流式扩散输出，默认开启扩散输出，用户可以切换。
- 扩散输出使用 `stream: true` 和 `diffusing: true`，必须展示接口实际返回的去噪过程。
- 正确处理普通增量与扩散全量帧的不同语义。扩散过程中，同一条回答应实时呈现文本修订，包括前文被修改、长度发生变化的情况。
- 扩散结束时准确显示最终文本；历史记录和后续对话上下文使用最终结果。
- 处理只有结束信息、没有正文的事件，以及工具调用前后出现的多个生成阶段，避免最后一帧丢失、已有内容被清空或不同阶段相互覆盖。
- 支持该模型的思考强度选项，具体参数以官方文档为准。

扩散请求体示意：

```json
{
  "model": "mercury-3",
  "messages": [{"role": "user", "content": "解释一下扩散语言模型"}],
  "stream": true,
  "diffusing": true
}
```

## 四、Google Gemini

本题使用 Gemini 原生 Generate Content REST API，接入 `gemini-3.8-flash`、`gemini-4-argon`：

- 流式端点：与模型名有关，示例：`https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse`
- 使用 `x-goog-api-key` 认证。
- 支持模型实际提供的思考强度配置，并开启思考摘要。
- 正确解析 `candidates[].content.parts[]`，分别处理回答文本、思考摘要、函数调用和签名元数据。
- 思考摘要根据 `thought` 标记识别并实时展示；摘要为空时也应正常完成请求。
- 正确处理 `thoughtSignature`：将其作为服务端返回的不透明数据原样保存和回传，保留与原始 Part 的对应关系和顺序。
- 支持带签名的函数调用及工具结果回传，保存历史后重启 APP，继续对话时签名和工具上下文应完整恢复。
- 不同 Part 的签名需要保持各自归属，不能通过把整条模型消息压成一个字符串而丢失结构。

注意：这里的“加密签名”指 Gemini 的 thought signature。思考摘要用于展示，签名用于保持协议上下文，两者分别存储和处理。

请求体示意：

```json
{
  "contents": [
    {"role": "user", "parts": [{"text": "解释一下多轮工具调用"}]}
  ],
  "generationConfig": {
    "thinkingConfig": {"includeThoughts": true}
  }
}
```

## 五、工具调用与历史记录

- 三家服务商都要完成“模型请求工具 → APP 执行 → 回传结果 → 模型继续回答”的闭环。
- 工具是否调用由模型返回的结构化调用决定，不能根据用户输入关键词直接拼出回答。
- 正确组装流式工具调用数据，在参数完整后执行；同一次调用只执行一次。
- 支持同一轮内的多个工具调用，以及工具回传后再次调用工具；设置合理的循环上限。
- 工具结果按各服务商的协议组织，保留调用标识及必要上下文。
- 工具执行状态出现在对应的对话位置，多次调用后显示顺序正确。
- 支持并行工具调用，节约用户时间。
- 如为填写 DeepSeek API Key，应以合适方式降级。
- 历史记录同时保存界面展示内容及继续请求所需的协议数据，包括思考内容、Gemini Parts 与签名、工具调用和结果。
- 每个会话记住所用服务商、模型和相关选项。读取历史后，应能继续完成多轮对话和工具调用。

## 六、流式处理与异常处理

- 使用 HarmonyOS 可用的网络能力自行实现 HTTP 和流式读取。第三方依赖须兼容 ArkTS 和当前项目环境。
- 收到网络数据后及时更新界面，不能等整个响应结束后再逐字播放。
- 正确处理 UTF-8 字符跨网络分片、SSE 事件跨分片、一次分片包含多个事件、LF/CRLF 换行和连接结束前的缓冲数据。
- DeepSeek、Mercury 和 Gemini 分别按各自协议识别结束、工具调用、错误及使用量等事件。
- 停止生成时终止当前请求及后续工具循环，并正确标记未完成内容。
- 生成过程中切换会话，迟到的数据不能写入其他会话。
- 对无效 Key、限流、网络中断、超时和响应解析失败显示可理解的提示，保留已经收到的内容。
- API Key 不得硬编码或写入日志，使用平台合适的安全存储方式。
- 不同的报错交给不同目标，工具报错和模型报错应准确处理。

## 参考资料

- DeepSeek 思考与工具调用：https://api-docs.deepseek.com/guides/thinking_mode/
- Deepseek Responses API 指南：https://api-docs.deepseek.com/zh-cn/guides/responses_api
- DeepSeek 网页搜索与抓取：https://api-docs.deepseek.com/zh-cn/guides/search
- DeepSeek Search API 参考：https://api-docs.deepseek.com/zh-cn/api/search
- DeepSeek Fetch API 参考：https://api-docs.deepseek.com/zh-cn/api/fetch
- OpenAI Responses API 概览：https://developers.openai.com/api/reference/responses/overview
- Mercury 模型：https://docs.inceptionlabs.ai/get-started/models
- Mercury 流式与扩散：https://docs.inceptionlabs.ai/capabilities/streaming
- OpenAI Chat Completions API 概览：https://developers.openai.com/api/reference/chat-completions/overview
- Gemini Generate Content REST：https://ai.google.dev/api/generate-content
- Gemini Generate Content 思考摘要：https://ai.google.dev/gemini-api/docs/generate-content/thinking
- Gemini Generate Content 签名：https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures

## 必须严格遵守的强制要求

- **禁止使用 Git。**
- **禁止读取工作目录的上一级目录及其中其他文件，包括 `..`，即使仅列出文件名也不允许。你的工作目录中的 `chat` 是项目根目录。**
