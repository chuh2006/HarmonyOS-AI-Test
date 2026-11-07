@ComponentV2
export struct AppIcon {
  @Param name: string = '';
  @Param iconSize: number = 20;
  @Param color: string = '#1C1D21';

  private res(): Resource {
    switch (this.name) {
      case 'menu': return $r('sys.symbol.list_bullet');
      case 'plus': return $r('sys.symbol.plus');
      case 'send': return $r('sys.symbol.arrow_up');
      case 'stop': return $r('sys.symbol.square_fill');
      case 'sliders': return $r('sys.symbol.gearshape');
      case 'chevron': return $r('sys.symbol.chevron_down');
      case 'search': return $r('sys.symbol.magnifyingglass');
      case 'globe': return $r('sys.symbol.link');
      case 'trash': return $r('sys.symbol.trash');
      case 'check': return $r('sys.symbol.checkmark');
      case 'close': return $r('sys.symbol.xmark');
      case 'retry': return $r('sys.symbol.arrow_clockwise');
      case 'sparkle': return $r('sys.symbol.wand_and_stars_fill');
      case 'copy': return $r('sys.symbol.square_and_square');
      case 'key': return $r('sys.symbol.key');
      default: return $r('sys.symbol.plus');
    }
  }

  build() {
    SymbolGlyph(this.res())
      .fontSize(this.iconSize)
      .fontColor([this.color])
  }
}