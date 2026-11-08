/**
 * Provider / model catalog with per-model capability flags.
 * The settings UI only shows controls that the current model supports.
 */
import { ProviderId, SessionOptions } from './Types';

export class ModelInfo {
  id: string = '';
  label: string = '';
  desc: string = '';
  /** Thinking controls are available for this model. */
  hasThinking: boolean = true;
  /** Thinking can be switched off entirely. */
  thinkingToggle: boolean = true;
  /** Allowed thinking levels while thinking is on. */
  thinkingLevels: string[] = [];
  /** Label of each thinking level, aligned with thinkingLevels. */
  thinkingLabels: string[] = [];
  /** reasoning.mode = pro | standard (OpenAI). */
  reasoningMode: boolean = false;
  /** Available service tiers ('standard' always implicit). */
  speedTiers: string[] = [];
  /** Mercury diffusion output. */
  diffusing: boolean = false;
}

export class ProviderInfo {
  id: ProviderId = 'deepseek';
  name: string = '';
  models: ModelInfo[] = [];
  defaultBaseUrl: string = '';
  baseUrlHint: string = '';
}

function m(id: string, desc: string): ModelInfo {
  const info: ModelInfo = new ModelInfo();
  info.id = id;
  info.label = id;
  info.desc = desc;
  return info;
}

function buildCatalog(): ProviderInfo[] {
  const list: ProviderInfo[] = [];

  // ---- DeepSeek (Anthropic Messages API) ----
  const ds: ProviderInfo = new ProviderInfo();
  ds.id = 'deepseek';
  ds.name = 'DeepSeek';
  ds.defaultBaseUrl = 'https://api.deepseek.com/anthropic';
  ds.baseUrlHint = '默认 https://api.deepseek.com/anthropic';
  const d1: ModelInfo = m('deepseek-flash', '极速响应 · 日常对话');
  d1.thinkingToggle = true;
  d1.thinkingLevels = ['low', 'high', 'max'];
  d1.thinkingLabels = ['低', '高', '极限'];
  const d2: ModelInfo = m('deepseek-v4-pro', '深度推理 · 复杂任务');
  d2.thinkingToggle = true;
  d2.thinkingLevels = ['low', 'high', 'max'];
  d2.thinkingLabels = ['低', '高', '极限'];
  ds.models.push(d1);
  ds.models.push(d2);

  // ---- OpenAI (Responses API) ----
  const oa: ProviderInfo = new ProviderInfo();
  oa.id = 'openai';
  oa.name = 'OpenAI';
  oa.defaultBaseUrl = 'https://api.openai.com/v1/responses';
  oa.baseUrlHint = '默认 https://api.openai.com/v1/responses';
  const o1: ModelInfo = m('gpt-6-astra', '旗舰 · 全能');
  o1.thinkingToggle = false;
  o1.thinkingLevels = ['low', 'medium', 'high', 'xhigh', 'max'];
  o1.thinkingLabels = ['低', '中', '高', '很高', '极限'];
  o1.reasoningMode = true;
  o1.speedTiers = ['fast', 'ultrafast'];
  const o2: ModelInfo = m('gpt-6.1-sol', '高效 · 均衡');
  o2.thinkingToggle = false;
  o2.thinkingLevels = ['low', 'medium', 'high', 'xhigh', 'max'];
  o2.thinkingLabels = ['低', '中', '高', '很高', '极限'];
  o2.reasoningMode = true;
  o2.speedTiers = ['fast', 'ultrafast'];
  const o3: ModelInfo = m('gpt-6.1-terra', '稳定 · 可靠');
  o3.thinkingToggle = true;
  o3.thinkingLevels = ['low', 'medium', 'high', 'xhigh', 'max'];
  o3.thinkingLabels = ['低', '中', '高', '很高', '极限'];
  o3.reasoningMode = true;
  o3.speedTiers = ['fast'];
  const o4: ModelInfo = m('gpt-6-luna', '轻量 · 极速');
  o4.thinkingToggle = true;
  o4.thinkingLevels = ['low', 'medium', 'high', 'xhigh', 'max'];
  o4.thinkingLabels = ['低', '中', '高', '很高', '极限'];
  o4.reasoningMode = true;
  o4.speedTiers = ['fast'];
  oa.models.push(o1);
  oa.models.push(o2);
  oa.models.push(o3);
  oa.models.push(o4);

  // ---- Inception Mercury ----
  const mc: ProviderInfo = new ProviderInfo();
  mc.id = 'mercury';
  mc.name = 'Mercury';
  mc.defaultBaseUrl = 'https://api.inceptionlabs.ai/v1/chat/completions';
  mc.baseUrlHint = '默认 https://api.inceptionlabs.ai/v1/chat/completions';
  const mm: ModelInfo = m('mercury-3', '扩散语言模型 · 极速生成');
  mm.thinkingToggle = false;
  mm.thinkingLevels = ['instant', 'low', 'medium', 'high'];
  mm.thinkingLabels = ['即时', '低', '中', '高'];
  mm.diffusing = true;
  mc.models.push(mm);

  // ---- Google Gemini ----
  const gg: ProviderInfo = new ProviderInfo();
  gg.id = 'gemini';
  gg.name = 'Gemini';
  gg.defaultBaseUrl = 'https://generativelanguage.googleapis.com';
  gg.baseUrlHint = '默认 https://generativelanguage.googleapis.com';
  const g1: ModelInfo = m('gemini-3.8-flash', '极速 · 多模态');
  g1.thinkingToggle = false;
  g1.thinkingLevels = ['low', 'medium', 'high'];
  g1.thinkingLabels = ['低', '中', '高'];
  const g2: ModelInfo = m('gemini-4-argon', '深度推理');
  g2.thinkingToggle = false;
  g2.thinkingLevels = ['low', 'medium', 'high'];
  g2.thinkingLabels = ['低', '中', '高'];
  gg.models.push(g1);
  gg.models.push(g2);

  list.push(ds);
  list.push(oa);
  list.push(mc);
  list.push(gg);
  return list;
}

export const PROVIDERS: ProviderInfo[] = buildCatalog();

export function providerInfo(providerId: string): ProviderInfo {
  for (let i = 0; i < PROVIDERS.length; i++) {
    if (PROVIDERS[i].id === providerId) {
      return PROVIDERS[i];
    }
  }
  return PROVIDERS[0];
}

export function modelInfo(providerId: string, modelId: string): ModelInfo {
  const p: ProviderInfo = providerInfo(providerId);
  for (let i = 0; i < p.models.length; i++) {
    if (p.models[i].id === modelId) {
      return p.models[i];
    }
  }
  return p.models[0];
}

export function defaultModelOf(providerId: string): string {
  return providerInfo(providerId).models[0].id;
}

export function providerShortName(providerId: string): string {
  return providerInfo(providerId).name;
}

/**
 * Clamp session options to what the current model actually supports.
 * Called before every request so that stale or hand-edited settings can
 * never produce an invalid parameter combination.
 */
export function normalizeOptions(providerId: string, modelId: string, o: SessionOptions): void {
  const info: ModelInfo = modelInfo(providerId, modelId);
  if (!info.thinkingToggle) {
    o.thinkingOn = true;
  }
  let lvlOk: boolean = false;
  for (let i = 0; i < info.thinkingLevels.length; i++) {
    if (info.thinkingLevels[i] === o.thinkingLevel) {
      lvlOk = true;
    }
  }
  if (!lvlOk && info.thinkingLevels.length > 0) {
    o.thinkingLevel = info.thinkingLevels[0];
  }
  if (info.thinkingLevels.length === 0 && providerId === 'mercury') {
    o.thinkingLevel = 'low';
  }
  if (info.reasoningMode && o.reasoningMode !== 'pro' && o.reasoningMode !== 'standard') {
    o.reasoningMode = 'standard';
  }
  if (o.speedTier === 'ultrafast' && info.speedTiers.indexOf('ultrafast') < 0) {
    o.speedTier = info.speedTiers.indexOf('fast') >= 0 ? 'fast' : 'standard';
  }
  if (o.speedTier === 'fast' && info.speedTiers.indexOf('fast') < 0) {
    o.speedTier = 'standard';
  }
}
