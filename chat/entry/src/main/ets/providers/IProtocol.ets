import { ChatError, Message, ModelConfig, StreamEvent } from '../types/Types';
import { AbortSignal } from '../services/HttpStream';

// 流式聊天回调
export interface StreamChatCallbacks {
  onEvent: (event: StreamEvent) => void;
  onComplete: () => void;
  onError: (error: ChatError) => void;
}

// 统一的Provider接口
export interface ChatProvider {
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void;
}
