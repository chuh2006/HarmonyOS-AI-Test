import { Message, ToolCall, ToolType } from '../types/Types';
import { DeepSeekTools } from '../services/DeepSeekTools';

@Component
export struct MessageBubble {
  @Prop message: Message;
  @State thinkingExpanded: boolean = false;

  build() {
    Column({ space: 8 }) {
      if (this.message.role === 'user') {
        Row() {
          Blank()
          Text(this.message.content)
            .fontSize(15)
            .fontColor('#FFFFFF')
            .backgroundColor('#007AFF')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(16)
            .constraintSize({ maxWidth: '80%' })
        }
        .width('100%')
      } else if (this.message.role === 'assistant') {
        Column({ space: 6 }) {
          if (this.hasThinking()) {
            this.ThinkingBlock()
          }

          if (this.hasToolCalls()) {
            ForEach(this.toolCalls(), (toolCall: ToolCall) => {
              this.ToolCallCard(toolCall)
            }, (toolCall: ToolCall) => `${toolCall.id}_${toolCall.status}`)
          }

          if (this.message.content.length > 0) {
            Row() {
              Text(this.message.content)
                .fontSize(15)
                .fontColor('#000000')
                .backgroundColor('#F0F0F0')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(16)
                .constraintSize({ maxWidth: '80%' })
              Blank()
            }
            .width('100%')
          } else if (this.message.status === 'streaming' || this.message.status === 'thinking') {
            Row({ space: 6 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color('#007AFF')
              Text('正在输入')
                .fontSize(13)
                .fontColor('#999999')
            }
            .width('100%')
          }

          if (this.message.status === 'error' && this.hasErrorText()) {
            Text(this.errorText())
              .fontSize(13)
              .fontColor('#FF3B30')
              .padding({ left: 4, top: 2 })
          } else if (this.message.status === 'stopped') {
            Text('已停止')
              .fontSize(12)
              .fontColor('#FF9500')
              .padding({ left: 4, top: 2 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
  }

  @Builder
  ThinkingBlock() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('思考过程')
          .fontSize(13)
          .fontColor('#666666')
          .fontWeight(FontWeight.Medium)

        Text(this.thinkingExpanded ? '收起' : '展开')
          .fontSize(12)
          .fontColor('#007AFF')
      }
      .onClick(() => {
        this.thinkingExpanded = !this.thinkingExpanded;
      })

      if (this.thinkingExpanded) {
        Text(this.thinkingText())
          .fontSize(13)
          .fontColor('#666666')
          .backgroundColor('#F5F5F5')
          .padding(10)
          .borderRadius(8)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ToolCallCard(toolCall: ToolCall) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.toolIcon(toolCall.type))
          .fontSize(14)

        Text(DeepSeekTools.getToolCallSummary(toolCall.type, toolCall.arguments))
          .fontSize(13)
          .fontColor('#333333')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (toolCall.status === 'running') {
          LoadingProgress()
            .width(12)
            .height(12)
            .color('#007AFF')
        } else if (toolCall.status === 'complete') {
          Text('完成')
            .fontSize(12)
            .fontColor('#34C759')
        } else if (toolCall.status === 'error') {
          Text('失败')
            .fontSize(12)
            .fontColor('#FF3B30')
        }
      }
      .width('100%')

      if (this.toolDetail(toolCall).length > 0) {
        Text(this.toolDetail(toolCall))
          .fontSize(12)
          .fontColor('#666666')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FAFAFA')
    .borderRadius(10)
    .border({ width: 1, color: '#E5E5E5' })
  }

  private hasThinking(): boolean {
    return this.message.thinking !== undefined && this.message.thinking.length > 0;
  }

  private thinkingText(): string {
    return this.message.thinking !== undefined ? this.message.thinking : '';
  }

  private hasToolCalls(): boolean {
    return this.message.toolCalls !== undefined && this.message.toolCalls.length > 0;
  }

  private toolCalls(): ToolCall[] {
    return this.message.toolCalls !== undefined ? this.message.toolCalls : [];
  }

  private hasErrorText(): boolean {
    return this.message.error !== undefined && this.message.error.length > 0;
  }

  private errorText(): string {
    return this.message.error !== undefined ? this.message.error : '';
  }

  private toolDetail(toolCall: ToolCall): string {
    if (toolCall.status === 'pending' || toolCall.status === 'running') {
      return '';
    }
    if (toolCall.status === 'error') {
      return toolCall.error !== undefined && toolCall.error.length > 0 ? toolCall.error : '执行失败';
    }
    // 给用户看的是一句话摘要，不是搜索/抓取到的正文
    return toolCall.resultSummary !== undefined && toolCall.resultSummary.length > 0
      ? toolCall.resultSummary : '完成';
  }

  private toolIcon(type: ToolType): string {
    return type === 'search' ? '🔍' : '📄';
  }
}
