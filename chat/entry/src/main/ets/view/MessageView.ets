/**
 * Message rendering: user bubbles, assistant turns with collapsible thinking,
 * live tool cards and a small status footer.
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { Block, Msg, BLOCK_TEXT, BLOCK_THINKING, BLOCK_TOOL, MSG_USER } from '../services/Types';
import { toolDisplayName, toolArgsPreview } from '../services/Tools';
import { formatClock, truncate, oneLine } from '../common/Util';
import { showToast } from '../common/Ui';
import {
  COLOR_BORDER, COLOR_ERR, COLOR_ERR_SOFT, COLOR_OK, COLOR_OK_SOFT, COLOR_PRIMARY,
  COLOR_PRIMARY_SOFT, COLOR_SURFACE, COLOR_SURFACE_SOFT, COLOR_TEXT, COLOR_TEXT_2,
  COLOR_TEXT_3, COLOR_WARN, COLOR_WARN_SOFT, FONT_SMALL, FONT_TINY, GRAD_USER
} from './Theme';
import { IconCheck, IconChevron, IconCopy, IconDoc, IconRetry, IconSearch, IconSparkle, IconWarn } from './Icons';

@Component
struct ThinkingBlockView {
  @ObjectLink block: Block;

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        IconSparkle('#8A8A96', 12)
        Text('思考过程')
          .fontSize(FONT_SMALL - 0.5)
          .fontColor(COLOR_TEXT_2)
          .fontWeight(FontWeight.Medium)
        Blank()
        IconChevron(COLOR_TEXT_3, 18, this.block.uiOpen)
      }
      .width('100%')
      .onClick(() => {
        this.block.uiTouched = true;
        this.block.uiOpen = !this.block.uiOpen;
      })

      if (this.block.uiOpen && this.block.text.length > 0) {
        Text(this.block.text)
          .fontSize(13)
          .fontColor(COLOR_TEXT_3)
          .lineHeight(20)
          .width('100%')
      } else if (!this.block.uiOpen && this.block.text.length > 0) {
        Text(oneLine(truncate(this.block.text, 64)))
          .fontSize(12)
          .fontColor(COLOR_TEXT_3)
          .maxLines(1)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(COLOR_SURFACE_SOFT)
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct TextBlockView {
  @ObjectLink block: Block;

  build() {
    Text(this.block.text)
      .fontSize(16)
      .fontColor(COLOR_TEXT)
      .lineHeight(25)
      .width('100%')
      .copyOption(CopyOptions.LocalDevice)
  }
}

@Component
struct ToolBlockView {
  @ObjectLink block: Block;

  @Builder
  statusPill() {
    if (this.block.toolStatus === 'running') {
      Row({ space: 4 }) {
        LoadingProgress().width(13).height(13).color(COLOR_PRIMARY)
        Text('执行中').fontSize(11).fontColor(COLOR_PRIMARY)
      }
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(999)
      .backgroundColor(COLOR_PRIMARY_SOFT)
    } else if (this.block.toolStatus === 'done') {
      Row({ space: 3 }) {
        IconCheck(COLOR_OK, 13)
        Text('完成').fontSize(11).fontColor(COLOR_OK)
      }
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(999)
      .backgroundColor(COLOR_OK_SOFT)
    } else if (this.block.toolStatus === 'error') {
      Row({ space: 3 }) {
        IconWarn(COLOR_ERR, 13)
        Text('失败').fontSize(11).fontColor(COLOR_ERR)
      }
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(999)
      .backgroundColor(COLOR_ERR_SOFT)
    } else {
      Text('准备中')
        .fontSize(11)
        .fontColor(COLOR_TEXT_3)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(999)
        .backgroundColor(COLOR_SURFACE_SOFT)
    }
  }

  build() {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Column() {
          if (this.block.toolName === 'fetch') {
            IconDoc(COLOR_PRIMARY, 18)
          } else {
            IconSearch(COLOR_PRIMARY, 16)
          }
        }
        .width(28).height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(14)
        .backgroundColor(COLOR_PRIMARY_SOFT)

        Text(toolDisplayName(this.block.toolName))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Blank()
        this.statusPill()
      }
      .width('100%')

      Text(toolArgsPreview(this.block.toolName, this.block.toolArgs))
        .fontSize(12.5)
        .fontColor(COLOR_TEXT_2)
        .maxLines(1)
        .width('100%')

      if (this.block.toolSummary.length > 0) {
        Text(this.block.toolSummary)
          .fontSize(12)
          .fontColor(COLOR_TEXT_3)
          .maxLines(1)
          .width('100%')
      }
      if (this.block.toolDetail.length > 0) {
        Text(this.block.toolDetail)
          .fontSize(11.5)
          .fontColor(COLOR_TEXT_3)
          .lineHeight(17)
          .maxLines(3)
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(14)
    .backgroundColor(COLOR_SURFACE)
    .border({ width: 1, color: COLOR_BORDER })
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct MessageView {
  @ObjectLink msg: Msg;
  /** Live status label shown while this message is streaming. */
  @Prop liveLabel: string = '';
  onRetry: () => void = () => {};

  private copyAll(): void {
    let text: string = '';
    for (let i = 0; i < this.msg.blocks.length; i++) {
      const b: Block = this.msg.blocks[i];
      if (b.kind === BLOCK_TEXT && b.text.length > 0) {
        text += b.text + '\n';
      }
    }
    const content: string = text.trim();
    if (content.length === 0) {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      showToast('已复制到剪贴板');
    }).catch(() => {
      showToast('复制失败');
    });
  }

  @Builder
  statusChip() {
    if (this.msg.status === 'streaming') {
      Row({ space: 5 }) {
        LoadingProgress().width(12).height(12).color(COLOR_PRIMARY)
        Text(this.liveLabel.length > 0 ? this.liveLabel : '生成中')
          .fontSize(FONT_TINY)
          .fontColor(COLOR_PRIMARY)
      }
    } else if (this.msg.status === 'stopped') {
      Row({ space: 4 }) {
        IconWarn(COLOR_WARN, 13)
        Text('已停止').fontSize(FONT_TINY).fontColor(COLOR_WARN)
      }
    } else if (this.msg.status === 'error') {
      Row({ space: 4 }) {
        IconWarn(COLOR_ERR, 13)
        Text('失败').fontSize(FONT_TINY).fontColor(COLOR_ERR)
      }
    } else {
      Row({ space: 3 }) {
        IconCheck(COLOR_OK, 13)
        Text('完成').fontSize(FONT_TINY).fontColor(COLOR_OK)
      }
    }
  }

  @Builder
  footer() {
    Row({ space: 12 }) {
      this.statusChip()
      Text(this.msg.modelLabel.length > 0 ?
        this.msg.modelLabel + ' · ' + formatClock(this.msg.createdAt) : formatClock(this.msg.createdAt))
        .fontSize(FONT_TINY)
        .fontColor(COLOR_TEXT_3)
      Blank()
      if (this.msg.status === 'error' || this.msg.status === 'stopped') {
        Row({ space: 4 }) {
          IconRetry(COLOR_PRIMARY, 15)
          Text('重试').fontSize(FONT_TINY).fontColor(COLOR_PRIMARY)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(999)
        .backgroundColor(COLOR_PRIMARY_SOFT)
        .onClick(() => {
          this.onRetry();
        })
      }
      Row({ space: 4 }) {
        IconCopy(COLOR_TEXT_3, 14)
        Text('复制').fontSize(FONT_TINY).fontColor(COLOR_TEXT_3)
      }
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .borderRadius(999)
      .onClick(() => {
        this.copyAll();
      })
    }
    .width('100%')
    .margin({ top: 2 })
  }

  @Builder
  errorBox() {
    if (this.msg.status === 'error' && this.msg.errorText.length > 0) {
      Row({ space: 8 }) {
        IconWarn(COLOR_ERR, 16)
        Text(this.msg.errorText)
          .fontSize(12.5)
          .fontColor(COLOR_ERR)
          .lineHeight(18)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(10)
      .borderRadius(12)
      .backgroundColor(COLOR_ERR_SOFT)
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  assistantBody() {
    Column() {
      if (this.msg.blocks.length > 0) {
        Column({ space: 10 }) {
          ForEach(this.msg.blocks, (b: Block) => {
            if (b.kind === BLOCK_THINKING) {
              ThinkingBlockView({ block: b })
            } else if (b.kind === BLOCK_TOOL) {
              ToolBlockView({ block: b })
            } else {
              TextBlockView({ block: b })
            }
          }, (b: Block) => b.uid)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      this.errorBox()
      this.footer()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  userBody() {
    Row() {
      Blank().layoutWeight(1)
      Text(this.msg.firstText())
        .fontSize(16)
        .fontColor('#FFFFFF')
        .lineHeight(24)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 })
        .linearGradient({ angle: 135, colors: [[GRAD_USER[0], 0], [GRAD_USER[1], 1]] })
        .constraintSize({ maxWidth: '84%' })
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
  }

  build() {
    if (this.msg.role === MSG_USER) {
      this.userBody()
    } else {
      this.assistantBody()
    }
  }
}
