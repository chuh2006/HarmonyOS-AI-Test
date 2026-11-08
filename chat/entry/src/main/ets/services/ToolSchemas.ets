/** Tool schema builders - each provider has its own tool declaration format. */

const SEARCH_DESC: string = '搜索互联网网页，返回与查询相关的结构化搜索结果（标题、链接、摘要）。当你需要查找实时信息、新闻、事实核对或不了解的内容时使用该工具。';
const FETCH_DESC: string = '抓取一个网页并返回其正文的 Markdown 文本。当你已经知道具体网址、或需要阅读某篇搜索结果的全文时使用该工具。';

const SEARCH_PARAMS: string = '{"type":"object","properties":{"query":{"type":"string","description":"搜索关键词，1-128 个字符"},"count":{"type":"integer","description":"返回结果条数，默认 5，最多 10"}},"required":["query"]}';
const FETCH_PARAMS: string = '{"type":"object","properties":{"url":{"type":"string","description":"要抓取的 HTTP/HTTPS 网页地址"}},"required":["url"]}';

/** Responses API (OpenAI): flat function tools. */
const OPENAI_TOOLS_JSON: string =
  '[{"type":"function","name":"search","description":"' + SEARCH_DESC + '","parameters":' + SEARCH_PARAMS + '},' +
  '{"type":"function","name":"fetch","description":"' + FETCH_DESC + '","parameters":' + FETCH_PARAMS + '}]';

/** Chat Completions (Mercury): functions nested under "function". */
const CHAT_COMPLETIONS_TOOLS_JSON: string =
  '[{"type":"function","function":{"name":"search","description":"' + SEARCH_DESC + '","parameters":' + SEARCH_PARAMS + '}},' +
  '{"type":"function","function":{"name":"fetch","description":"' + FETCH_DESC + '","parameters":' + FETCH_PARAMS + '}}]';

/** Anthropic Messages (DeepSeek): name + input_schema, no type field. */
const ANTHROPIC_TOOLS_JSON: string =
  '[{"name":"search","description":"' + SEARCH_DESC + '","input_schema":' + SEARCH_PARAMS + '},' +
  '{"name":"fetch","description":"' + FETCH_DESC + '","input_schema":' + FETCH_PARAMS + '}]';

/** Gemini: functionDeclarations. */
const GEMINI_TOOLS_JSON: string =
  '[{"functionDeclarations":[{"name":"search","description":"' + SEARCH_DESC + '","parameters":' + SEARCH_PARAMS + '},' +
  '{"name":"fetch","description":"' + FETCH_DESC + '","parameters":' + FETCH_PARAMS + '}]}]';

export function openaiToolsJson(): string {
  return OPENAI_TOOLS_JSON;
}

export function chatCompletionsToolsJson(): string {
  return CHAT_COMPLETIONS_TOOLS_JSON;
}

export function anthropicToolsJson(): string {
  return ANTHROPIC_TOOLS_JSON;
}

export function geminiToolsJson(): string {
  return GEMINI_TOOLS_JSON;
}
