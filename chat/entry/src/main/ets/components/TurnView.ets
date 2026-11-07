import { Segment, Turn, isBusy, modelSpec, statusLabel } from '../core/Models';
import { pasteboard } from '@kit.BasicServicesKit';

@Component
export struct TurnView {
  @Prop turn: Turn;
  @Prop last: boolean = false;
  onRetry: () => void = () => {};
  @State expanded: string[] = [];
  private toggle(id: string): void {
    this.expanded = this.expanded.includes(id) ? this.expanded.filter((v: string) => v !== id) : this.expanded.concat(id);
  }
  private copy(): void {
    const text = this.turn.segments.filter((s: Segment) => s.kind === 'text').map((s: Segment) => s.text).join('\n\n');
    pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
      .then(() => this.getUIContext().getPromptAction().showToast({ message: '已复制' }))
      .catch(() => this.getUIContext().getPromptAction().showToast({ message: '复制失败，请长按选择文字' }));
  }
  @Builder
  thought(index: number) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('✦').fontSize(14).fontColor('#52756A')
        Text('思考过程').fontSize(13).fontColor('#52756A').layoutWeight(1)
        Text(this.expanded.includes(this.turn.segments[index].id) ? '收起 −' : '展开 +').fontSize(12).fontColor('#789088')
      }.width('100%').onClick(() => this.toggle(this.turn.segments[index].id)).accessibilityText('展开或收起思考过程')
      if (this.expanded.includes(this.turn.segments[index].id)) {
        Text(this.turn.segments[index].text).fontSize(14).fontColor('#63716A').lineHeight(23).width('100%').copyOption(CopyOptions.LocalDevice)
      }
    }.width('100%').padding(14).backgroundColor('#EDF2ED').borderRadius(14)
  }
  @Builder
  tool(index: number) {
    Column({ space: 8 }) {
      Row({ space: 9 }) {
        Text(this.turn.segments[index].state === 'running' || this.turn.segments[index].state === 'pending' ? '◌' : this.turn.segments[index].state === 'failed' ? '!' : '↗')
          .fontSize(17).fontColor(this.turn.segments[index].state === 'failed' ? '#A65B40' : '#376D5C')
        Column({ space: 4 }) {
          Text(this.turn.segments[index].name === 'fetch' ? '读取网页' : '搜索资料').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#324C42')
          Text(this.turn.segments[index].state === 'completed' ? this.turn.segments[index].detail : this.turn.segments[index].state === 'failed' ? '查询失败' :
            this.turn.segments[index].state === 'stopped' ? '已停止' : this.turn.segments[index].state === 'pending' ? '准备查询' : '正在查阅…')
            .fontSize(12).fontColor('#819087').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.expanded.includes(this.turn.segments[index].id) ? '−' : '+').fontColor('#819087')
      }.width('100%').onClick(() => this.toggle(this.turn.segments[index].id)).accessibilityText('查看工具查询详情')
      if (this.expanded.includes(this.turn.segments[index].id)) {
        Text(this.turn.segments[index].text || '正在接收查询参数').fontSize(12).fontColor('#65756C').width('100%').copyOption(CopyOptions.LocalDevice)
        if (this.turn.segments[index].state === 'failed') { Text(this.turn.segments[index].detail).fontSize(12).fontColor('#A65B40').width('100%') }
        ForEach(this.turn.segments[index].links, (link: string, sourceIndex: number) => {
          if (/^https?:\/\//.test(link)) {
            Hyperlink(link, this.turn.segments[index].titles[sourceIndex] || link).color('#286C58').width('100%')
          }
        }, (link: string, sourceIndex: number) => sourceIndex.toString() + link)
      }
    }.width('100%').padding(14).borderRadius(14).border({ width: 1, color: '#E1E7DF' }).backgroundColor('#FCFDF9')
  }
  build() {
    Column({ space: 20 }) {
      Row() {
        Blank().width(24)
        Text(this.turn.user).fontSize(16).fontColor('#253B32').lineHeight(25).copyOption(CopyOptions.LocalDevice)
          .padding({ left: 18, right: 18, top: 14, bottom: 14 }).backgroundColor('#E8EDE5')
          .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 5 })
      }.width('100%').justifyContent(FlexAlign.End)
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          Text('m').fontFamily('serif').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .width(27).height(27).textAlign(TextAlign.Center).backgroundColor('#285D4A').borderRadius(9)
          Text(modelSpec(this.turn.model).name).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#607268')
          Blank()
          if (isBusy(this.turn.status)) { LoadingProgress().width(16).height(16).color('#527566') }
        }.width('100%')
        ForEach(this.turn.segments, (segment: Segment, index: number) => {
          if (segment.kind === 'thought') { this.thought(index) }
          else if (segment.kind === 'tool') { this.tool(index) }
          else if (segment.kind === 'notice') {
            Text(this.turn.segments[index].text).fontSize(12).fontColor('#8B7957').width('100%').lineHeight(19)
          } else {
            Text(this.turn.segments[index].text).fontSize(16).lineHeight(27).fontColor('#293C33').width('100%')
              .copyOption(CopyOptions.LocalDevice).textAlign(TextAlign.Start)
          }
        }, (segment: Segment) => segment.id)
        if (this.turn.error) {
          Text(this.turn.error).fontSize(13).lineHeight(21).fontColor('#A05D43').width('100%')
            .padding(13).backgroundColor('#FAEFE7').borderRadius(12).copyOption(CopyOptions.LocalDevice)
        }
        Row({ space: 14 }) {
          Text(statusLabel(this.turn.status)).fontSize(11).fontColor('#85948B')
          if (!isBusy(this.turn.status) && this.turn.segments.some((s: Segment) => s.kind === 'text')) {
            Button('复制', { type: ButtonType.Normal }).fontSize(12).fontColor('#6C8174').backgroundColor(Color.Transparent)
              .height(30).padding({ left: 5, right: 5 }).onClick(() => this.copy())
          }
          if (this.last && (this.turn.status === 'failed' || this.turn.status === 'stopped')) {
            Button('重新生成', { type: ButtonType.Normal }).fontSize(12).fontColor('#286C58').backgroundColor('#E7EEE6')
              .height(30).borderRadius(9).onClick(() => this.onRetry()).id('retryButton')
          }
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ top: 12, bottom: 22 })
  }
}
