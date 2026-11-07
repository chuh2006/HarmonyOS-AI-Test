export class ModelSpec {
  id: string;
  name: string;
  provider: string;
  efforts: string[];
  tiers: string[];
  constructor(id: string, name: string, provider: string, efforts: string[], tiers: string[] = []) {
    this.id = id; this.name = name; this.provider = provider; this.efforts = efforts; this.tiers = tiers;
  }
}

export const MODELS: ModelSpec[] = [
  new ModelSpec('deepseek-flash', 'DeepSeek Flash', 'deepseek', ['none', 'low', 'high', 'max']),
  new ModelSpec('deepseek-v4-pro', 'DeepSeek V4 Pro', 'deepseek', ['none', 'low', 'high', 'max']),
  new ModelSpec('gpt-6-astra', 'GPT-6 Astra', 'openai', ['low', 'medium', 'high', 'xhigh', 'max'], ['standard', 'fast', 'ultrafast']),
  new ModelSpec('gpt-6.1-sol', 'GPT-6.1 Sol', 'openai', ['low', 'medium', 'high', 'xhigh', 'max'], ['standard', 'fast', 'ultrafast']),
  new ModelSpec('gpt-6.1-terra', 'GPT-6.1 Terra', 'openai', ['none', 'low', 'medium', 'high', 'xhigh', 'max'], ['standard', 'fast']),
  new ModelSpec('gpt-6-luna', 'GPT-6 Luna', 'openai', ['none', 'low', 'medium', 'high', 'xhigh', 'max'], ['standard', 'fast']),
  new ModelSpec('mercury-3', 'Mercury 3', 'mercury', ['instant', 'low', 'medium', 'high']),
  new ModelSpec('gemini-3.8-flash', 'Gemini 3.8 Flash', 'gemini', ['low', 'medium', 'high']),
  new ModelSpec('gemini-4-argon', 'Gemini 4 Argon', 'gemini', ['low', 'medium', 'high'])
];

export class Options {
  model: string = 'deepseek-flash';
  effort: string = 'high';
  mode: string = 'standard';
  tier: string = 'standard';
  diffusing: boolean = true;
  tools: boolean = true;
}

export class ProviderConfig {
  id: string;
  name: string;
  baseUrl: string;
  constructor(id: string, name: string, baseUrl: string) {
    this.id = id; this.name = name; this.baseUrl = baseUrl;
  }
}

export function defaultProviders(): ProviderConfig[] {
  return [
    new ProviderConfig('deepseek', 'DeepSeek', 'https://api.deepseek.com/anthropic'),
    new ProviderConfig('openai', 'OpenAI', 'https://api.openai.com/v1'),
    new ProviderConfig('mercury', 'Inception', 'https://api.inceptionlabs.ai/v1'),
    new ProviderConfig('gemini', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta')
  ];
}

export function modelSpec(id: string): ModelSpec { return MODELS.find((m: ModelSpec) => m.id === id) || MODELS[0]; }
export function normalizeOptions(options: Options): Options {
  const model = modelSpec(options.model);
  options.model = model.id;
  if (!model.efforts.includes(options.effort)) { options.effort = model.efforts.includes('medium') ? 'medium' : 'high'; }
  if (!model.tiers.includes(options.tier)) { options.tier = 'standard'; }
  if (options.mode !== 'pro') { options.mode = 'standard'; }
  return options;
}

export function uid(): string { return Date.now().toString(36) + Math.random().toString(36).slice(2, 10); }

export class Segment {
  id: string = uid();
  kind: string = 'text';
  text: string = '';
  name: string = '';
  detail: string = '';
  state: string = '';
  links: string[] = [];
  titles: string[] = [];
}

export class Turn {
  id: string = uid();
  user: string = '';
  model: string = '';
  segments: Segment[] = [];
  status: string = 'requesting';
  error: string = '';
  // Complete protocol exchanges only. Draft output is persisted separately.
  replay: string[] = [];
  draft: string[] = [];
  usage: string[] = [];
  created: number = Date.now();
}

export class Session {
  id: string = uid();
  title: string = '新对话';
  options: Options = new Options();
  turns: Turn[] = [];
  updated: number = Date.now();
}

export class Archive {
  version: number = 1;
  active: string = '';
  providers: ProviderConfig[] = defaultProviders();
  sessions: Session[] = [];
}

export function isBusy(status: string): boolean {
  return ['requesting', 'thinking', 'tools', 'answering'].includes(status);
}
export function statusLabel(status: string): string {
  const labels: Record<string, string> = {
    'requesting': '正在连接', 'thinking': '思考中', 'tools': '正在查阅资料', 'answering': '正在回答',
    'completed': '完成', 'stopped': '已停止', 'failed': '生成失败'
  };
  return labels[status] || status;
}
