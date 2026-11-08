/**
 * Core data model. Every class is @Observed so that streaming mutations
 * propagate to the UI through @ObjectLink bindings.
 */

export type ProviderId = 'deepseek' | 'openai' | 'mercury' | 'gemini';

export const BLOCK_TEXT: string = 'text';
export const BLOCK_THINKING: string = 'thinking';
export const BLOCK_TOOL: string = 'tool';

export const MSG_USER: string = 'user';
export const MSG_ASSISTANT: string = 'assistant';

export const ST_STREAMING: string = 'streaming';
export const ST_DONE: string = 'done';
export const ST_STOPPED: string = 'stopped';
export const ST_ERROR: string = 'error';

export const TOOL_PENDING: string = 'pending';
export const TOOL_RUNNING: string = 'running';
export const TOOL_DONE: string = 'done';
export const TOOL_FAILED: string = 'error';

export const TOOL_SEARCH: string = 'search';
export const TOOL_FETCH: string = 'fetch';

/** Runtime phase of the engine, mirrored in the composer status pill. */
export const PHASE_IDLE: string = 'idle';
export const PHASE_REQUESTING: string = 'requesting';
export const PHASE_THINKING: string = 'thinking';
export const PHASE_TOOL: string = 'tool';
export const PHASE_ANSWERING: string = 'answering';
export const PHASE_DONE: string = 'done';
export const PHASE_STOPPED: string = 'stopped';
export const PHASE_ERROR: string = 'error';

@Observed
export class Block {
  uid: string = '';
  kind: string = BLOCK_TEXT;
  /** Text body for text/thinking blocks. */
  text: string = '';
  /** Thinking fold state (UI only). */
  uiOpen: boolean = false;
  uiTouched: boolean = false;
  /** Tool call state. */
  toolId: string = '';
  toolName: string = '';
  toolTitle: string = '';
  toolArgs: string = '';
  toolStatus: string = TOOL_PENDING;
  toolSummary: string = '';
  toolDetail: string = '';
  /** Result handed back to the model (JSON string). */
  toolResult: string = '';
  /** The model-visible result is ready. */
  toolFinished: boolean = false;

  static make(kind: string, uid: string): Block {
    const b: Block = new Block();
    b.uid = uid;
    b.kind = kind;
    return b;
  }
}

@Observed
export class Msg {
  id: string = '';
  role: string = MSG_USER;
  status: string = ST_DONE;
  errorText: string = '';
  createdAt: number = 0;
  /** Provider specific raw payload needed to replay this message (JSON string). */
  proto: string = '';
  /** Provider that produced the raw payload; a mismatch forces safe synthesis. */
  protoProvider: string = '';
  blocks: Block[] = [];
  /** Model that produced the message, shown in the footer. */
  modelLabel: string = '';

  firstText(): string {
    for (let i = 0; i < this.blocks.length; i++) {
      const b: Block = this.blocks[i];
      if (b.kind === BLOCK_TEXT && b.text.length > 0) {
        return b.text;
      }
    }
    return '';
  }

  hasToolBlocks(): boolean {
    for (let i = 0; i < this.blocks.length; i++) {
      if (this.blocks[i].kind === BLOCK_TOOL) {
        return true;
      }
    }
    return false;
  }
}

@Observed
export class SessionOptions {
  thinkingOn: boolean = true;
  thinkingLevel: string = 'low';
  reasoningMode: string = 'standard';
  /** 'standard' | 'fast' | 'ultrafast' */
  speedTier: string = 'standard';
  diffusing: boolean = true;
}

@Observed
export class Session {
  id: string = '';
  title: string = '新会话';
  createdAt: number = 0;
  updatedAt: number = 0;
  providerId: string = 'deepseek';
  modelId: string = 'deepseek-flash';
  options: SessionOptions = new SessionOptions();
  messages: Msg[] = [];
}

export function defaultOptionsFor(provider: string): SessionOptions {
  const o: SessionOptions = new SessionOptions();
  if (provider === 'deepseek') {
    o.thinkingOn = true;
    o.thinkingLevel = 'low';
  } else if (provider === 'openai') {
    o.thinkingOn = true;
    o.thinkingLevel = 'medium';
    o.reasoningMode = 'standard';
    o.speedTier = 'standard';
  } else if (provider === 'mercury') {
    o.thinkingOn = true;
    o.thinkingLevel = 'low';
    o.diffusing = true;
  } else {
    o.thinkingOn = true;
    o.thinkingLevel = 'medium';
  }
  return o;
}
