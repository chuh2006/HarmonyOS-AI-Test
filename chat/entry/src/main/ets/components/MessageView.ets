import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { ChatMessage, MessageBlock, BlockKind, ToolStatus, MsgStatus, Role } from '../model/Types';
import { Theme } from '../common/Theme';
import { AppIcon } from '../common/AppIcon';

interface ToolArgsView {
  query?: string;
  url?: string;
}

interface SearchItemView {
  title?: string;
  url?: string;
}

interface SearchResultView {
  results?: SearchItemView[];
}

function hostOf(u: string): string {
  let rest = u;
  const scheme = rest.indexOf('://');
  if (scheme >= 0) {
    rest = rest.substring(scheme + 3);
  }
  const slash = rest.indexOf('/');
  return slash >= 0 ? rest.substring(0, slash) : rest;
}

function toolSubtitle(block: MessageBlock): string {
  try {
    const args = JSON.parse(block.toolArgs) as ToolArgsView;
    if (block.toolName === 'search') {
      return args.query ?? '';
    }
    return args.url ?? '';
  } catch (e) {
    return '';
  }
}

function copyText(text: string): void {
  const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
  pasteboard.getSystemPasteboard().setData(data).then(() => {
    promptAction.showToast({ message: '已复制', duration: 1500 });
  });
}

@ComponentV2
struct ThinkingView {
  @Param block: MessageBlock = new MessageBlock(BlockKind.THINKING, '');
  @Param active: boolean = false;

  build() {
    Column() {
      Row() {
        AppIcon({ name: 'sparkle', iconSize: 13, color: Theme.ink3 })
        Text(this.active && !this.block.collapsed ? '正在思考' : '思考过程')
          .fontSize(12.5)
          .fontColor(Theme.ink2)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 6 })
        if (this.active && !this.block.collapsed) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color(Theme.ink3)
            .margin({ left: 6 })
        }
        Blank()
        Text(this.block.collapsed ? '展开' : '收起')
          .fontSize(12)
          .fontColor(Theme.ink3)
      }
      .width('100%')
      .onClick(() => {
        this.block.collapsed = !this.block.collapsed;
      })

      if (!this.block.collapsed) {
        Text(this.block.text)
          .fontSize(13)
          .lineHeight(21)
          .fontColor(Theme.ink2)
          .width('100%')
          .margin({ top: 8 })
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.thinkingBg)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
struct ToolView {
  @Param block: MessageBlock = new MessageBlock(BlockKind.TOOL, '');
  @Local expanded: boolean = false;

  private running(): boolean {
    return this.block.toolStatus === ToolStatus.RUNNING ||
      this.block.toolStatus === ToolStatus.STREAMING || this.block.toolStatus === ToolStatus.WAITING;
  }

  private results(): SearchItemView[] {
    if (this.block.toolName !== 'search' || this.block.toolResult.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(this.block.toolResult) as SearchResultView;
      const all = parsed.results ?? [];
      return all.slice(0, 3);
    } catch (e) {
      return [];
    }
  }

  build() {
    Column() {
      Row() {
        Row() {
          AppIcon({
            name: this.block.toolName === 'search' ? 'search' : 'globe',
            iconSize: 15,
            color: Theme.accent
          })
        }
        .width(28)
        .height(28)
        .borderRadius(9)
        .backgroundColor(Theme.accentSoft)
        .justifyContent(FlexAlign.Center)

        Column() {
          Text(this.block.toolName === 'search' ? '网页搜索' : '网页抓取')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ink)
          if (toolSubtitle(this.block).length > 0) {
            Text(toolSubtitle(this.block))
              .fontSize(12)
              .fontColor(Theme.ink2)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })

        if (this.running()) {
          LoadingProgress().width(16).height(16).color(Theme.accent)
        } else if (this.block.toolStatus === ToolStatus.DONE) {
          AppIcon({ name: 'check', iconSize: 16, color: Theme.ok })
        } else if (this.block.toolStatus === ToolStatus.ERROR) {
          Text('!')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.danger)
            .width(16)
            .textAlign(TextAlign.Center)
        } else {
          Text('–').fontSize(14).fontColor(Theme.ink3)
        }
      }
      .width('100%')

      if (!this.running() && this.block.toolDisplay.length > 0) {
        Text(this.block.toolStatus === ToolStatus.ERROR ? this.block.toolError : this.block.toolDisplay)
          .fontSize(12)
          .fontColor(this.block.toolStatus === ToolStatus.ERROR ? Theme.danger : Theme.ink2)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 8 })
      }

      if (this.expanded && this.results().length > 0) {
        Column() {
          ForEach(this.results(), (item: SearchItemView) => {
            Column() {
              Text(item.title ?? '')
                .fontSize(12.5)
                .fontColor(Theme.ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(hostOf(item.url ?? ''))
                .fontSize(11)
                .fontColor(Theme.ink3)
                .margin({ top: 1 })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (item: SearchItemView, index: number) => `${index}_${item.url ?? ''}`)
        }
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(Theme.surface)
    .borderRadius(14)
    .border({ width: 1, color: Theme.line })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (this.results().length > 0) {
        this.expanded = !this.expanded;
      }
    })
  }
}

@ComponentV2
struct BlockView {
  @Param block: MessageBlock = new MessageBlock(BlockKind.TEXT, '');
  @Param active: boolean = false;

  build() {
    if (this.block.kind === BlockKind.THINKING) {
      ThinkingView({ block: this.block, active: this.active })
    } else if (this.block.kind === BlockKind.TOOL) {
      ToolView({ block: this.block })
    } else {
      Text(this.block.text)
        .fontSize(16)
        .lineHeight(26)
        .fontColor(Theme.ink)
        .width('100%')
        .textAlign(TextAlign.Start)
        .copyOption(CopyOptions.LocalDevice)
    }
  }
}

@ComponentV2
export struct MessageView {
  @Param msg: ChatMessage = new ChatMessage('', Role.ASSISTANT);
  @Param modelLabel: string = '';
  @Param active: boolean = false;
  @Event onRetry: () => void = () => {};
  @Event onSetup: () => void = () => {};

  private statusText(): string {
    switch (this.msg.status) {
      case MsgStatus.REQUESTING: return '正在请求…';
      case MsgStatus.THINKING: return '思考中…';
      case MsgStatus.TOOL: return '正在执行工具…';
      case MsgStatus.ANSWERING: return '回答中…';
      default: return '';
    }
  }

  private isActiveStatus(): boolean {
    return this.msg.status === MsgStatus.REQUESTING || this.msg.status === MsgStatus.THINKING ||
      this.msg.status === MsgStatus.TOOL || this.msg.status === MsgStatus.ANSWERING;
  }

  build() {
    if (this.msg.role === Role.USER) {
      Row() {
        Text(this.msg.textContent())
          .fontSize(16)
          .lineHeight(24)
          .fontColor(Color.White)
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(18)
          .copyOption(CopyOptions.LocalDevice)
          .constraintSize({ maxWidth: '84%' })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    } else {
      Column() {
        Row() {
          Row() {
            AppIcon({ name: 'sparkle', iconSize: 12, color: Theme.accent })
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(Theme.accentSoft)
          .justifyContent(FlexAlign.Center)

          Text(this.modelLabel)
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.ink2)
            .margin({ left: 7 })
        }
        .width('100%')
        .margin({ bottom: 10 })

        ForEach(this.msg.blocks, (block: MessageBlock) => {
          BlockView({ block: block, active: this.active && this.isActiveStatus() })
            .margin({ bottom: 8 })
        }, (block: MessageBlock) => block.id)

        if (this.active && this.isActiveStatus()) {
          Row() {
            LoadingProgress().width(14).height(14).color(Theme.accent)
            Text(this.statusText())
              .fontSize(13)
              .fontColor(Theme.ink2)
              .margin({ left: 7 })
          }
          .width('100%')
          .margin({ top: 2 })
        } else if (this.msg.status === MsgStatus.FAILED) {
          Column() {
            Text(this.msg.error)
              .fontSize(13)
              .lineHeight(20)
              .fontColor(Theme.danger)
              .width('100%')
            Row() {
              Row() {
                AppIcon({ name: 'retry', iconSize: 14, color: Theme.accent })
                Text('重试').fontSize(13).fontColor(Theme.accent).margin({ left: 5 })
              }
              .padding({ top: 6, bottom: 6, right: 10 })
              .onClick(() => this.onRetry())

              if (this.msg.error.includes('Key')) {
                Row() {
                  AppIcon({ name: 'key', iconSize: 14, color: Theme.accent })
                  Text('去设置').fontSize(13).fontColor(Theme.accent).margin({ left: 5 })
                }
                .padding(6)
                .onClick(() => this.onSetup())
              }
            }
            .width('100%')
            .margin({ top: 6 })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Theme.dangerSoft)
          .borderRadius(14)
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 4 })
        } else if (this.msg.status === MsgStatus.STOPPED) {
          Text('已停止生成')
            .fontSize(12)
            .fontColor(Theme.ink3)
            .margin({ top: 2 })
        } else if (this.msg.status === MsgStatus.DONE) {
          Row() {
            if (this.msg.usageText.length > 0) {
              Text(this.msg.usageText)
                .fontSize(11)
                .fontColor(Theme.ink3)
            }
            Blank()
            Row() {
              AppIcon({ name: 'copy', iconSize: 14, color: Theme.ink3 })
            }
            .padding(6)
            .onClick(() => copyText(this.msg.textContent()))
          }
          .width('100%')
          .margin({ top: 2 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}