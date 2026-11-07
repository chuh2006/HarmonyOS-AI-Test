import { AppStore } from '../viewmodel/AppStore';
import { Conversation } from '../model/Types';
import { modelInfo } from '../model/Catalog';
import { Theme } from '../common/Theme';
import { AppIcon } from '../common/AppIcon';

function formatTime(ts: number): string {
  const d = new Date(ts);
  const now = new Date();
  const hh = `${d.getHours()}`.padStart(2, '0');
  const mm = `${d.getMinutes()}`.padStart(2, '0');
  if (d.toDateString() === now.toDateString()) {
    return `${hh}:${mm}`;
  }
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

@ComponentV2
export struct SessionDrawer {
  @Param store: AppStore = AppStore.getInstance();
  @Event onClose: () => void = () => {};
  @Event onSettings: () => void = () => {};

  private confirmDelete(conv: Conversation): void {
    AlertDialog.show({
      title: '删除会话',
      message: `确定删除「${conv.title}」吗？此操作不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: () => {
          this.store.deleteConversation(conv.id);
        }
      }
    });
  }

  build() {
    Row() {
      Column() {
        Row() {
          Text('会话')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink)
          Blank()
          Row() {
            AppIcon({ name: 'close', iconSize: 17, color: Theme.ink2 })
          }
          .width(32)
          .height(32)
          .borderRadius(16)
          .backgroundColor(Theme.bg)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.onClose())
        }
        .width('100%')
        .margin({ bottom: 14 })

        Row() {
          AppIcon({ name: 'plus', iconSize: 16, color: Theme.accent })
          Text('新建会话')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.accent)
            .margin({ left: 6 })
        }
        .width('100%')
        .padding({ top: 11, bottom: 11 })
        .borderRadius(13)
        .backgroundColor(Theme.accentSoft)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.store.newChat();
          this.onClose();
        })

        List() {
          ForEach(this.store.conversations, (conv: Conversation) => {
            ListItem() {
              Row() {
                Column() {
                  Text(conv.title)
                    .fontSize(14.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${modelInfo(conv.model).label} · ${formatTime(conv.updatedAt)}`)
                    .fontSize(11.5)
                    .fontColor(Theme.ink3)
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Row() {
                  AppIcon({ name: 'trash', iconSize: 15, color: Theme.ink3 })
                }
                .width(30)
                .height(30)
                .borderRadius(15)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.confirmDelete(conv);
                })
              }
              .width('100%')
              .padding({ left: 12, right: 6, top: 11, bottom: 11 })
              .borderRadius(13)
              .backgroundColor(conv.id === this.store.currentId ? Theme.accentSoft : Color.Transparent)
              .onClick(() => {
                this.store.switchTo(conv.id);
                this.onClose();
              })
            }
          }, (conv: Conversation) => `${conv.id}_${conv.updatedAt}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .margin({ top: 10 })

        Row() {
          AppIcon({ name: 'sliders', iconSize: 17, color: Theme.ink2 })
          Text('设置')
            .fontSize(14)
            .fontColor(Theme.ink2)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ top: 12, bottom: 12, left: 12 })
        .borderRadius(13)
        .onClick(() => {
          this.onSettings();
        })
      }
      .width(292)
      .height('100%')
      .padding({ left: 16, right: 16, top: 52, bottom: 20 })
      .backgroundColor(Theme.surface)
      .alignItems(HorizontalAlign.Start)
      .transition(TransitionEffect.move(TransitionEdge.START).animation({ duration: 220, curve: Curve.EaseOut }))

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.32)')
        .onClick(() => this.onClose())
        .transition(TransitionEffect.opacity(0).animation({ duration: 220 }))
    }
    .width('100%')
    .height('100%')
  }
}