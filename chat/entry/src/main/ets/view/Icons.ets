/**
 * Hand-drawn line icons (vector primitives keep the look consistent and
 * themeable without any raster assets). Every icon scales via its size param.
 */

@Builder
export function IconMenu(color: string, size: number) {
  Column({ space: size * 0.2 }) {
    Rect().width(size).height(size * 0.1).radius(size * 0.05).fill(color)
    Rect().width(size).height(size * 0.1).radius(size * 0.05).fill(color)
    Rect().width(size).height(size * 0.1).radius(size * 0.05).fill(color)
  }.width(size).height(size).alignItems(HorizontalAlign.Start)
}

@Builder
export function IconSliders(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Line().startPoint([size * 0.05, size * 0.3]).endPoint([size * 0.95, size * 0.3])
      .stroke(color).strokeWidth(size * 0.09)
    Line().startPoint([size * 0.05, size * 0.7]).endPoint([size * 0.95, size * 0.7])
      .stroke(color).strokeWidth(size * 0.09)
    Circle().width(size * 0.3).height(size * 0.3).fill(color)
      .margin({ left: size * 0.6, top: size * 0.15 })
    Circle().width(size * 0.3).height(size * 0.3).fill(color)
      .margin({ left: size * 0.25, top: size * 0.55 })
  }.width(size).height(size)
}

@Builder
export function IconSend(color: string, size: number) {
  Path()
    .commands(`M ${size * 0.5} ${size * 0.16} L ${size * 0.83} ${size * 0.57} L ${size * 0.62} ${size * 0.57} L ${size * 0.62} ${size * 0.84} L ${size * 0.38} ${size * 0.84} L ${size * 0.38} ${size * 0.57} L ${size * 0.17} ${size * 0.57} Z`)
    .fill(color)
    .stroke(color)
    .strokeWidth(size * 0.05)
    .strokeLineJoin(LineJoinStyle.Round)
    .width(size).height(size)
}

@Builder
export function IconStop(color: string, size: number) {
  Rect().width(size * 0.46).height(size * 0.46).radius(size * 0.12).fill(color)
}

@Builder
export function IconChevron(color: string, size: number, up: boolean) {
  Path()
    .commands(up ?
      `M ${size * 0.22} ${size * 0.63} L ${size * 0.5} ${size * 0.35} L ${size * 0.78} ${size * 0.63}` :
      `M ${size * 0.22} ${size * 0.37} L ${size * 0.5} ${size * 0.65} L ${size * 0.78} ${size * 0.37}`)
    .stroke(color)
    .strokeWidth(size * 0.1)
    .strokeLineCap(LineCapStyle.Round)
    .strokeLineJoin(LineJoinStyle.Round)
    .fill('rgba(0,0,0,0)')
    .width(size).height(size)
}

@Builder
export function IconPlus(color: string, size: number) {
  Stack() {
    Line().startPoint([size * 0.5, size * 0.15]).endPoint([size * 0.5, size * 0.85])
      .stroke(color).strokeWidth(size * 0.095).strokeLineCap(LineCapStyle.Round)
    Line().startPoint([size * 0.15, size * 0.5]).endPoint([size * 0.85, size * 0.5])
      .stroke(color).strokeWidth(size * 0.095).strokeLineCap(LineCapStyle.Round)
  }.width(size).height(size)
}

@Builder
export function IconSearch(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Circle().width(size * 0.62).height(size * 0.62)
      .stroke(color).strokeWidth(size * 0.085).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.05, top: size * 0.05 })
    Line().startPoint([size * 0.58, size * 0.58]).endPoint([size * 0.9, size * 0.9])
      .stroke(color).strokeWidth(size * 0.085).strokeLineCap(LineCapStyle.Round)
  }.width(size).height(size)
}

@Builder
export function IconGlobe(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Circle().width(size * 0.85).height(size * 0.85)
      .stroke(color).strokeWidth(size * 0.075).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.075, top: size * 0.075 })
    Ellipse().width(size * 0.4).height(size * 0.85)
      .stroke(color).strokeWidth(size * 0.065).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.3, top: size * 0.075 })
    Line().startPoint([size * 0.1, size * 0.5]).endPoint([size * 0.9, size * 0.5])
      .stroke(color).strokeWidth(size * 0.065)
  }.width(size).height(size)
}

@Builder
export function IconSparkle(color: string, size: number) {
  Path()
    .commands(`M ${size * 0.5} ${size * 0.04} C ${size * 0.5} ${size * 0.32} ${size * 0.68} ${size * 0.5} ${size * 0.96} ${size * 0.5} C ${size * 0.68} ${size * 0.5} ${size * 0.5} ${size * 0.68} ${size * 0.5} ${size * 0.96} C ${size * 0.5} ${size * 0.68} ${size * 0.32} ${size * 0.5} ${size * 0.04} ${size * 0.5} C ${size * 0.32} ${size * 0.5} ${size * 0.5} ${size * 0.32} ${size * 0.5} ${size * 0.04} Z`)
    .fill(color)
    .width(size).height(size)
}

@Builder
export function IconClose(color: string, size: number) {
  Stack() {
    Line().startPoint([size * 0.25, size * 0.25]).endPoint([size * 0.75, size * 0.75])
      .stroke(color).strokeWidth(size * 0.09).strokeLineCap(LineCapStyle.Round)
    Line().startPoint([size * 0.75, size * 0.25]).endPoint([size * 0.25, size * 0.75])
      .stroke(color).strokeWidth(size * 0.09).strokeLineCap(LineCapStyle.Round)
  }.width(size).height(size)
}

@Builder
export function IconCopy(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Rect().width(size * 0.52).height(size * 0.62).radius(size * 0.14)
      .stroke(color).strokeWidth(size * 0.07).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.1, top: size * 0.1 })
    Rect().width(size * 0.52).height(size * 0.62).radius(size * 0.14)
      .stroke(color).strokeWidth(size * 0.07).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.35, top: size * 0.33 })
  }.width(size).height(size)
}

@Builder
export function IconRetry(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Path()
      .commands(`M ${size * 0.5} ${size * 0.2} C ${size * 0.67} ${size * 0.2} ${size * 0.8} ${size * 0.33} ${size * 0.8} ${size * 0.5} C ${size * 0.8} ${size * 0.67} ${size * 0.67} ${size * 0.8} ${size * 0.5} ${size * 0.8} C ${size * 0.33} ${size * 0.8} ${size * 0.2} ${size * 0.67} ${size * 0.2} ${size * 0.53}`)
      .stroke(color)
      .strokeWidth(size * 0.085)
      .strokeLineCap(LineCapStyle.Round)
      .fill('rgba(0,0,0,0)')
      .width(size).height(size)
    Path()
      .commands(`M ${size * 0.09} ${size * 0.51} L ${size * 0.2} ${size * 0.33} L ${size * 0.31} ${size * 0.51} Z`)
      .fill(color)
      .width(size).height(size)
  }.width(size).height(size)
}

@Builder
export function IconTrash(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Line().startPoint([size * 0.32, size * 0.24]).endPoint([size * 0.68, size * 0.24])
      .stroke(color).strokeWidth(size * 0.075).strokeLineCap(LineCapStyle.Round)
    Path()
      .commands(`M ${size * 0.25} ${size * 0.3} L ${size * 0.75} ${size * 0.3} L ${size * 0.7} ${size * 0.78} C ${size * 0.695} ${size * 0.82} ${size * 0.66} ${size * 0.85} ${size * 0.62} ${size * 0.85} L ${size * 0.38} ${size * 0.85} C ${size * 0.34} ${size * 0.85} ${size * 0.305} ${size * 0.82} ${size * 0.3} ${size * 0.78} Z`)
      .stroke(color)
      .strokeWidth(size * 0.07)
      .fill('rgba(0,0,0,0)')
      .strokeLineJoin(LineJoinStyle.Round)
      .width(size).height(size)
    Line().startPoint([size * 0.5, size * 0.4]).endPoint([size * 0.5, size * 0.72])
      .stroke(color).strokeWidth(size * 0.065).strokeLineCap(LineCapStyle.Round)
    Line().startPoint([size * 0.38, size * 0.16]).endPoint([size * 0.62, size * 0.16])
      .stroke(color).strokeWidth(size * 0.07).strokeLineCap(LineCapStyle.Round)
  }.width(size).height(size)
}

@Builder
export function IconCheck(color: string, size: number) {
  Path()
    .commands(`M ${size * 0.2} ${size * 0.52} L ${size * 0.42} ${size * 0.74} L ${size * 0.8} ${size * 0.32}`)
    .stroke(color)
    .strokeWidth(size * 0.11)
    .strokeLineCap(LineCapStyle.Round)
    .strokeLineJoin(LineJoinStyle.Round)
    .fill('rgba(0,0,0,0)')
    .width(size).height(size)
}

@Builder
export function IconChat(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Rect().width(size * 0.9).height(size * 0.7).radius(size * 0.28)
      .stroke(color).strokeWidth(size * 0.075).fill('rgba(0,0,0,0)')
      .margin({ left: size * 0.05, top: size * 0.1 })
    Path().commands(`M ${size * 0.3} ${size * 0.72} L ${size * 0.3} ${size * 0.95} L ${size * 0.53} ${size * 0.72} Z`)
      .fill(color).width(size).height(size)
  }.width(size).height(size)
}

@Builder
export function IconDoc(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Path()
      .commands(`M ${size * 0.24} ${size * 0.12} L ${size * 0.57} ${size * 0.12} L ${size * 0.76} ${size * 0.31} L ${size * 0.76} ${size * 0.88} L ${size * 0.24} ${size * 0.88} Z`)
      .stroke(color)
      .strokeWidth(size * 0.075)
      .fill('rgba(0,0,0,0)')
      .strokeLineJoin(LineJoinStyle.Round)
      .width(size).height(size)
    Line().startPoint([size * 0.57, size * 0.13]).endPoint([size * 0.57, size * 0.31]).stroke(color).strokeWidth(size * 0.065)
    Line().startPoint([size * 0.57, size * 0.31]).endPoint([size * 0.755, size * 0.31]).stroke(color).strokeWidth(size * 0.065)
    Line().startPoint([size * 0.35, size * 0.52]).endPoint([size * 0.65, size * 0.52])
      .stroke(color).strokeWidth(size * 0.06).strokeLineCap(LineCapStyle.Round)
    Line().startPoint([size * 0.35, size * 0.67]).endPoint([size * 0.65, size * 0.67])
      .stroke(color).strokeWidth(size * 0.06).strokeLineCap(LineCapStyle.Round)
  }.width(size).height(size)
}

@Builder
export function IconWarn(color: string, size: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    Path()
      .commands(`M ${size * 0.5} ${size * 0.12} L ${size * 0.92} ${size * 0.87} L ${size * 0.08} ${size * 0.87} Z`)
      .stroke(color)
      .strokeWidth(size * 0.085)
      .fill('rgba(0,0,0,0)')
      .strokeLineJoin(LineJoinStyle.Round)
      .width(size).height(size)
    Line().startPoint([size * 0.5, size * 0.38]).endPoint([size * 0.5, size * 0.62])
      .stroke(color).strokeWidth(size * 0.09).strokeLineCap(LineCapStyle.Round)
    Circle().width(size * 0.09).height(size * 0.09).fill(color)
      .margin({ left: size * 0.455, top: size * 0.71 })
  }.width(size).height(size)
}
