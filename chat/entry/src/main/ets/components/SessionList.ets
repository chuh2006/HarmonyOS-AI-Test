import { Session, getProviderName } from '../types/Types';

@Component
export struct SessionList {
  @Prop sessions: Session[];
  @Prop currentSessionId: string;
  onSelectSession: (sessionId: string) => void = () => {
  };
  onNewSession: () => void = () => {
  };
  onDeleteSession: (sessionId: string) => void = () => {
  };
  onClose: () => void = () => {
  };

  build() {
    Column() {
      Row() {
        Text('会话')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)

        Blank()

        Button('新建')
          .fontSize(13)
          .height(32)
          .backgroundColor('#007AFF')
          .onClick(() => {
            this.onNewSession();
          })

        Button('关闭')
          .fontSize(13)
          .height(32)
          .margin({ left: 8 })
          .backgroundColor('#E5E5E5')
          .fontColor('#000000')
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#F8F8F8')

      if (this.sessions.length === 0) {
        Column({ space: 12 }) {
          Blank()
          Text('暂无会话')
            .fontSize(15)
            .fontColor('#999999')
          Button('开始新对话')
            .fontSize(14)
            .onClick(() => {
              this.onNewSession();
            })
          Blank()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.sessions, (session: Session) => {
            ListItem() {
              this.SessionItem(session)
            }
          }, (session: Session) => `${session.id}_${session.updatedAt}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(16)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  SessionItem(session: Session) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(session.title)
          .fontSize(15)
          .fontWeight(this.currentSessionId === session.id ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.currentSessionId === session.id ? '#007AFF' : '#000000')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 6 }) {
          Text(getProviderName(session.modelConfig.providerId))
            .fontSize(11)
            .fontColor('#666666')

          Text('·')
            .fontSize(11)
            .fontColor('#CCCCCC')

          Text(session.modelConfig.modelId)
            .fontSize(11)
            .fontColor('#999999')

          Text('·')
            .fontSize(11)
            .fontColor('#CCCCCC')

          Text(this.formatTime(session.updatedAt))
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('删除')
        .fontSize(12)
        .height(28)
        .backgroundColor('#FF3B30')
        .onClick(() => {
          this.onDeleteSession(session.id);
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.currentSessionId === session.id ? '#E6F2FF' : '#F8F8F8')
    .borderRadius(10)
    .onClick(() => {
      this.onSelectSession(session.id);
    })
  }

  private formatTime(timestamp: number): string {
    const diff: number = Date.now() - timestamp;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)}分钟前`;
    }
    if (diff < 86400000) {
      return `${Math.floor(diff / 3600000)}小时前`;
    }
    if (diff < 604800000) {
      return `${Math.floor(diff / 86400000)}天前`;
    }
    const date: Date = new Date(timestamp);
    return `${date.getMonth() + 1}/${date.getDate()}`;
  }
}
