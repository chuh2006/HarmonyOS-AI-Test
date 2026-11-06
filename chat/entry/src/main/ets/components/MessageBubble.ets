import { Message, ToolCall } from '../types/Types';
import { DeepSeekTools } from '../services/DeepSeekTools';

@Component
export struct MessageBubble {
  @Prop message: Message;
  @State thinkingExpanded: boolean = false;
  
  build() {
    Column({ space: 8 }) {
      // 用户消息
      if (this.message.role === 'user') {
        Row() {
          Blank()
          Text(this.message.content)
            .fontSize(15)
            .fontColor('#FFFFFF')
            .backgroundColor('#007AFF')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(16)
            .maxWidth('80%')
        }
        .width('100%')
      }
      
      // 助手消息
      else if (this.message.role === 'assistant') {
        Column({ space: 6 }) {
          // 思考内容(可折叠)
          if (this.message.thinking) {
            Column({ space: 4 }) {
              Row({ space: 4 }) {
                Text('💭')
                  .fontSize(14)
                
                Text('思考过程')
                  .fontSize(13)
                  .fontColor('#666666')
                  .fontWeight(FontWeight.Medium)
                
                Text(this.thinkingExpanded ? '▲' : '▼')
                  .fontSize(10)
                  .fontColor('#999999')
              }
              .onClick(() => {
                this.thinkingExpanded = !this.thinkingExpanded;
              })
              
              if (this.thinkingExpanded) {
                Text(this.message.thinking)
                  .fontSize(13)
                  .fontColor('#666666')
                  .backgroundColor('#F5F5F5')
                  .padding(8)
                  .borderRadius(8)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          
          // 工具调用
          if (this.message.toolCalls && this.message.toolCalls.length > 0) {
            ForEach(this.message.toolCalls, (toolCall: ToolCall) => {
              this.ToolCallCard(toolCall)
            })
          }
          
          // 主要内容
          if (this.message.content || this.message.status === 'streaming') {
            Row() {
              Text(this.message.content || (this.message.status === 'streaming' ? '...' : ''))
                .fontSize(15)
                .fontColor('#000000')
                .backgroundColor('#F0F0F0')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(16)
                .maxWidth('80%')
              
              Blank()
            }
            .width('100%')
          }
          
          // 错误信息
          if (this.message.status === 'error' && this.message.error) {
            Text(`❌ ${this.message.error}`)
              .fontSize(13)
              .fontColor('#FF3B30')
              .padding({ left: 12, top: 4 })
          }
          
          // 状态指示器
          if (this.message.status === 'streaming') {
            Row({ space: 4 }) {
              LoadingProgress()
                .width(12)
                .height(12)
                .color('#007AFF')
              
              Text('生成中...')
                .fontSize(12)
                .fontColor('#999999')
            }
            .padding({ left: 12 })
          } else if (this.message.status === 'stopped') {
            Text('⏹ 已停止')
              .fontSize(12)
              .fontColor('#FF9500')
              .padding({ left: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      
      // 工具结果消息(不单独显示，已在工具调用卡片中展示)
      else if (this.message.role === 'tool') {
        // 空
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }
  
  @Builder
  ToolCallCard(toolCall: ToolCall) {
    Column({ space: 4 }) {
      // 工具调用标题
      Row({ space: 6 }) {
        Text(this.getToolIcon(toolCall.type))
          .fontSize(14)
        
        Text(DeepSeekTools.getToolCallSummary(toolCall.type, toolCall.arguments))
          .fontSize(13)
          .fontColor('#333333')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        
        // 状态指示器
        if (toolCall.status === 'running') {
          LoadingProgress()
            .width(12)
            .height(12)
            .color('#007AFF')
        } else if (toolCall.status === 'complete') {
          Text('✓')
            .fontSize(12)
            .fontColor('#34C759')
        } else if (toolCall.status === 'error') {
          Text('✗')
            .fontSize(12)
            .fontColor('#FF3B30')
        }
      }
      .width('100%')
      
      // 工具结果预览
      if (toolCall.status === 'complete' && toolCall.result) {
        Text(DeepSeekTools.getResultSummary({ success: true, data: toolCall.result }))
          .fontSize(12)
          .fontColor('#666666')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (toolCall.status === 'error' && toolCall.error) {
        Text(toolCall.error)
          .fontSize(12)
          .fontColor('#FF3B30')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#FAFAFA')
    .borderRadius(10)
    .border({ width: 1, color: '#E5E5E5' })
  }
  
  private getToolIcon(type: string): string {
    switch (type) {
      case 'search':
        return '🔍';
      case 'fetch':
        return '📄';
      default:
        return '🔧';
    }
  }
}
