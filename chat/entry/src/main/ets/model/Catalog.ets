import { ProviderId } from './Types';

export class ModelInfo {
  id: string = '';
  label: string = '';
  tagline: string = '';
  provider: ProviderId = ProviderId.DEEPSEEK;
  efforts: string[] = [];
  canDisableThinking: boolean = false;
  supportsProMode: boolean = false;
  supportsFast: boolean = false;
  supportsUltrafast: boolean = false;
  supportsDiffusing: boolean = false;
}

export class ProviderInfo {
  id: ProviderId = ProviderId.DEEPSEEK;
  label: string = '';
  defaultBaseUrl: string = '';
  keyHint: string = '';
}

export const PROVIDERS: ProviderInfo[] = [
  {
    id: ProviderId.DEEPSEEK,
    label: 'DeepSeek',
    defaultBaseUrl: 'https://api.deepseek.com/anthropic',
    keyHint: 'platform.deepseek.com 创建'
  },
  {
    id: ProviderId.OPENAI,
    label: 'OpenAI',
    defaultBaseUrl: 'https://api.openai.com/v1',
    keyHint: 'platform.openai.com 创建'
  },
  {
    id: ProviderId.MERCURY,
    label: 'Inception',
    defaultBaseUrl: 'https://api.inceptionlabs.ai/v1',
    keyHint: 'platform.inceptionlabs.ai 创建'
  },
  {
    id: ProviderId.GEMINI,
    label: 'Gemini',
    defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    keyHint: 'aistudio.google.com 创建'
  }
];

function model(id: string, label: string, tagline: string, provider: ProviderId,
  efforts: string[], disable: boolean, pro: boolean, fast: boolean, ultra: boolean,
  diffusing: boolean): ModelInfo {
  const m = new ModelInfo();
  m.id = id;
  m.label = label;
  m.tagline = tagline;
  m.provider = provider;
  m.efforts = efforts;
  m.canDisableThinking = disable;
  m.supportsProMode = pro;
  m.supportsFast = fast;
  m.supportsUltrafast = ultra;
  m.supportsDiffusing = diffusing;
  return m;
}

export const MODELS: ModelInfo[] = [
  model('deepseek-flash', 'DeepSeek Flash', '轻快灵敏，日常对话', ProviderId.DEEPSEEK,
    ['low', 'high', 'max'], true, false, false, false, false),
  model('deepseek-v4-pro', 'DeepSeek V4 Pro', '深度推理，复杂任务', ProviderId.DEEPSEEK,
    ['low', 'high', 'max'], true, false, false, false, false),
  model('gpt-6-astra', 'GPT-6 Astra', '旗舰推理与创作', ProviderId.OPENAI,
    ['low', 'medium', 'high', 'xhigh', 'max'], false, true, true, true, false),
  model('gpt-6.1-sol', 'GPT-6.1 Sol', '专业 coding 与 agent', ProviderId.OPENAI,
    ['low', 'medium', 'high', 'xhigh', 'max'], false, true, true, true, false),
  model('gpt-6.1-terra', 'GPT-6.1 Terra', '高效精准，自然写作', ProviderId.OPENAI,
    ['none', 'low', 'medium', 'high', 'xhigh', 'max'], true, true, true, false, false),
  model('gpt-6-luna', 'GPT-6 Luna', '低延迟轻量之选', ProviderId.OPENAI,
    ['none', 'low', 'medium', 'high', 'xhigh', 'max'], true, true, true, false, false),
  model('mercury-3', 'Mercury 3', '扩散生成，极速输出', ProviderId.MERCURY,
    ['instant', 'low', 'medium', 'high'], false, false, false, false, true),
  model('gemini-3.8-flash', 'Gemini 3.8 Flash', '均衡灵敏', ProviderId.GEMINI,
    ['low', 'medium', 'high'], false, false, false, false, false),
  model('gemini-4-argon', 'Gemini 4 Argon', '新一代深度思考', ProviderId.GEMINI,
    ['low', 'medium', 'high'], false, false, false, false, false)
];

export function providerInfo(id: ProviderId): ProviderInfo {
  for (const p of PROVIDERS) {
    if (p.id === id) {
      return p;
    }
  }
  return PROVIDERS[0];
}

export function modelInfo(id: string): ModelInfo {
  for (const m of MODELS) {
    if (m.id === id) {
      return m;
    }
  }
  return MODELS[0];
}

export function modelsOf(provider: ProviderId): ModelInfo[] {
  const out: ModelInfo[] = [];
  for (const m of MODELS) {
    if (m.provider === provider) {
      out.push(m);
    }
  }
  return out;
}

export function defaultModelOf(provider: ProviderId): string {
  const list = modelsOf(provider);
  return list.length > 0 ? list[0].id : '';
}

export function effortLabel(effort: string): string {
  switch (effort) {
    case 'none': return '关闭';
    case 'instant': return '即时';
    case 'minimal': return '极低';
    case 'low': return '低';
    case 'medium': return '中';
    case 'high': return '高';
    case 'xhigh': return '超高';
    case 'max': return '极致';
    default: return effort;
  }
}