import { Conversation, ChatMessage, MsgStatus } from '../model/Types';
import { StreamHandle } from '../net/HttpClient';

export class ToolCallInfo {
  id: string = '';
  name: string = '';
  argsJson: string = '';

  constructor(id: string, name: string, argsJson: string) {
    this.id = id;
    this.name = name;
    this.argsJson = argsJson;
  }
}

export class PhaseResult {
  payload: string = '';
  toolCalls: ToolCallInfo[] = [];
  stopReason: string = '';
}

export interface StreamSink {
  status(s: MsgStatus): void;
  thinkingDelta(text: string): void;
  textDelta(text: string): void;
  textSnapshot(text: string): void;
  newTextBlock(): void;
  toolStart(id: string, name: string): void;
  toolArgs(id: string, fragment: string): void;
  toolReady(id: string, argsJson: string): void;
  usage(text: string): void;
}

export interface ProviderAdapter {
  streamPhase(conv: Conversation, apiKey: string, baseUrl: string, sink: StreamSink,
    handle: StreamHandle): Promise<PhaseResult>;
}

export function toolResultFor(msg: ChatMessage, toolId: string): string {
  const block = msg.findToolBlock(toolId);
  if (block !== null && block.toolResult.length > 0) {
    return block.toolResult;
  }
  return '{"error":"工具结果缺失，可能生成被中断。请基于已有信息继续。"}';
}

export function joinTexts(parts: string[]): string {
  let out = '';
  for (const p of parts) {
    out += p;
  }
  return out;
}

export function trimBaseUrl(url: string): string {
  let u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}