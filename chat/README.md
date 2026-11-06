# MiniChat - HarmonyOS AI聊天应用

一个功能完整的HarmonyOS AI聊天应用，支持多个服务商和大语言模型。

## 功能特性

### 支持的服务商和模型

1. **DeepSeek**
   - 模型：`deepseek-flash`, `deepseek-v4-pro`
   - 使用官方 Anthropic Messages API
   - 支持思考模式（low/high/max）
   - 支持流式输出和工具调用

2. **OpenAI GPT**
   - 模型：`gpt-6-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-luna`
   - 使用官方 Responses API（无状态模式）
   - 支持思考模式（low/medium/high/xhigh/max）
   - 支持推理模式（standard/pro）
   - 支持速度模式（normal/fast/ultrafast）
   - 正确保存和回传 `encrypted_content`

3. **Inception Mercury**
   - 模型：`mercury-3`
   - 支持普通流式输出和扩散输出
   - 扩散模式实时展示文本修订过程
   - 支持思考强度配置

4. **Google Gemini**
   - 模型：`gemini-3.8-flash`, `gemini-4-argon`
   - 使用原生 Generate Content REST API
   - 支持思考摘要和 `thoughtSignature` 处理
   - 正确维护 Parts 结构和签名对应关系

### 核心功能

- **多轮对话**：完整的会话管理和历史记录
- **实时流式输出**：即时显示生成的内容，无需等待完整响应
- **思考过程展示**：可折叠的思考内容区域，清晰区分思考与回答
- **工具调用**：
  - `search`：DeepSeek网页搜索
  - `fetch`：网页内容抓取
  - 支持并行工具调用
  - 支持多轮工具调用循环（最多10轮）
- **会话管理**：新建、切换、删除会话，重启应用后可继续对话
- **状态指示**：清晰显示请求中、思考中、工具执行中、回答中、完成、停止、错误等状态
- **错误处理**：友好的错误提示，保留已生成内容，支持重试
- **安全存储**：API Key使用HarmonyOS Preferences安全存储

### 技术亮点

- **流式处理**：
  - 正确处理UTF-8字符跨网络分片
  - 处理SSE事件跨分片和多事件情况
  - 支持LF/CRLF换行
  - 处理连接结束前的缓冲数据

- **协议适配**：
  - 各服务商独立适配器，正确实现各自API协议
  - 保存和回传协议特定数据（思考内容、签名、加密内容等）
  - 正确处理工具调用的结构化数据

- **扩散输出**：
  - Mercury的扩散模式实时展示文本修订
  - 处理全量帧与增量帧的不同语义
  - 准确显示最终文本

- **Gemini签名**：
  - 正确保存 `thoughtSignature`
  - 维护签名与Part的对应关系和顺序
  - 支持带签名的函数调用和结果回传

## 使用说明

### 1. 配置API Key

点击顶部右侧的设置按钮 ⚙，进入设置面板：

1. 选择服务商（DeepSeek/OpenAI/Mercury/Gemini）
2. 选择模型
3. 输入对应的API Key
4. （可选）自定义Base URL
5. 配置模型参数（思考模式、强度等）
6. 点击"完成"保存

### 2. 开始对话

- 在底部输入框输入消息
- 点击"发送"按钮或按回车键
- 观看实时流式输出

### 3. 会话管理

点击顶部左侧的菜单按钮 ☰：

- **新建会话**：创建新的对话
- **切换会话**：点击会话项切换到历史对话
- **删除会话**：点击"删除"按钮移除会话

### 4. 停止生成

生成过程中，点击"停止"按钮可终止当前请求。

### 5. 工具调用

当模型需要搜索或抓取网页时：
- 会自动调用DeepSeek的search/fetch工具
- 工具执行状态显示在消息中
- 工具结果摘要可见，完整结果用于模型继续回答
- 需要配置DeepSeek API Key才能使用工具功能

## 项目结构

```
chat/entry/src/main/ets/
├── types/
│   └── Types.ets              # 核心类型定义
├── services/
│   ├── HttpStream.ets         # HTTP和SSE流式处理
│   ├── Store.ets              # 数据持久化存储
│   ├── ChatEngine.ets         # 聊天引擎核心逻辑
│   └── DeepSeekTools.ets      # 工具调用实现
├── providers/
│   ├── DeepSeekProvider.ets   # DeepSeek适配器
│   ├── OpenAIProvider.ets     # OpenAI适配器
│   ├── MercuryProvider.ets    # Mercury适配器
│   └── GeminiProvider.ets     # Gemini适配器
├── components/
│   ├── MessageBubble.ets      # 消息气泡组件
│   ├── SettingsPanel.ets      # 设置面板组件
│   └── SessionList.ets        # 会话列表组件
└── pages/
    └── Index.ets              # 主页面
```

## 编译和运行

1. 在DevEco Studio中打开 `chat/` 目录
2. 等待项目同步完成
3. 连接HarmonyOS设备或启动模拟器
4. 点击运行按钮

## 权限说明

应用需要以下权限：
- `ohos.permission.INTERNET`：网络访问，调用AI API
- `ohos.permission.GET_NETWORK_INFO`：获取网络状态

## 注意事项

1. **API Key安全**：请勿将API Key硬编码或分享给他人
2. **网络要求**：需要稳定的网络连接才能使用
3. **费用**：使用各服务商API可能产生费用，请查看对应服务商的计费说明
4. **工具调用**：search和fetch工具使用DeepSeek API，需要配置DeepSeek Key
5. **会话限制**：最多保留50个会话，超过后自动清理最旧会话
6. **工具循环限制**：单次对话最多10轮工具调用，防止无限循环

## 已知限制

- HarmonyOS HTTP模块不支持真正的流式读取，当前实现通过分段处理模拟流式效果
- 扩散模式为实验性功能，可能不稳定
- 部分模型的某些参数组合可能不受服务商支持

## 开发者信息

- 开发框架：HarmonyOS ArkTS
- 最低版本：HarmonyOS 3.0+
- 构建工具：DevEco Studio

## 许可

本项目仅供学习和研究使用。
