# src/canvas.cr
require "bit_array"

enum RenderMode
  Braille
  LegacyOctant
end

class Canvas
  OCTANTS = begin
    chars = " 𜺨𜺫🮂𜴀▘𜴁𜴂𜴃𜴄▝𜴅𜴆𜴇𜴈▀𜴉𜴊𜴋𜴌🯦𜴍𜴎𜴏𜴐𜴑𜴒𜴓𜴔𜴕𜴖𜴗𜴘𜴙𜴚𜴛𜴜𜴝𜴞𜴟🯧𜴠𜴡𜴢𜴣𜴤𜴥𜴦𜴧𜴨𜴩𜴪𜴫𜴬𜴭𜴮𜴯𜴰𜴱𜴲𜴳𜴴𜴵🮅𜺣𜴶𜴷𜴸𜴹𜴺𜴻𜴼𜴽𜴾𜴿𜵀𜵁𜵂𜵃𜵄▖𜵅𜵆𜵇𜵈▌𜵉𜵊𜵋𜵌▞𜵍𜵎𜵏𜵐▛𜵑𜵒𜵓𜵔𜵕𜵖𜵗𜵘𜵙𜵚𜵛𜵜𜵝𜵞𜵟𜵠𜵡𜵢𜵣𜵤𜵥𜵦𜵧𜵨𜵩𜵪𜵫𜵬𜵭𜵮𜵯𜵰𜺠𜵱𜵲𜵳𜵴𜵵𜵶𜵷𜵸𜵹𜵺𜵻𜵼𜵽𜵾𜵿𜶀𜶁𜶂𜶃𜶄𜶅𜶆𜶇𜶈𜶉𜶊𜶋𜶌𜶍𜶎𜶏▗𜶐𜶑𜶒𜶓▚𜶔𜶕𜶖𜶗▐𜶘𜶙𜶚𜶛▜𜶜𜶝𜶞𜶟𜶠𜶡𜶢𜶣𜶤𜶥𜶦𜶧𜶨𜶩𜶪𜶫▂𜶬𜶭𜶮𜶯𜶰𜶱𜶲𜶳𜶴𜶵𜶶𜶷𜶸𜶹𜶺𜶻𜶼𜶽𜶾𜶿𜷀𜷁𜷂𜷃𜷄𜷅𜷆𜷇𜷈𜷉𜷊𜷋𜷌𜷍𜷎𜷏𜷐𜷑𜷒𜷓𜷔𜷕𜷖𜷗𜷘𜷙𜷚▄𜷛𜷜𜷝𜷞▙𜷟𜷠𜷡𜷢▟𜷣▆𜷤𜷥█".chars
    StaticArray(Char, 256).new { |i| chars[i] }
  end

  getter width : Int32
  getter height : Int32
  property render_mode : RenderMode = RenderMode::Braille

  def initialize(@width : Int32, @height : Int32)
    @buffer = BitArray.new(@width * @height)
  end

  def clear
    @buffer.fill(false)
  end

  def set_pixel(x : Int32, y : Int32, state : Bool = true)
    return unless 0 <= x && x < @width && 0 <= y && y < @height
    @buffer[y * @width + x] = state
  end

  def get_pixel(x : Int32, y : Int32) : Bool
    return false unless 0 <= x && x < @width && 0 <= y && y < @height
    @buffer[y * @width + x]
  end

  def to_s(io : IO)
    render_width = (@width / 2.0).ceil.to_i
    render_height = (@height / 4.0).ceil.to_i

    render_height.times do |by|
      render_width.times do |bx|
        base_x = bx * 2
        base_y = by * 4
        val = 0

        if @render_mode.braille?
          val |= 1 << 0 if get_pixel(base_x, base_y)
          val |= 1 << 1 if get_pixel(base_x, base_y + 1)
          val |= 1 << 2 if get_pixel(base_x, base_y + 2)
          val |= 1 << 3 if get_pixel(base_x + 1, base_y)
          val |= 1 << 4 if get_pixel(base_x + 1, base_y + 1)
          val |= 1 << 5 if get_pixel(base_x + 1, base_y + 2)
          val |= 1 << 6 if get_pixel(base_x, base_y + 3)
          val |= 1 << 7 if get_pixel(base_x + 1, base_y + 3)

          io << (0x2800 + val).chr
        else
          val |= 1 << 0 if get_pixel(base_x, base_y)
          val |= 1 << 1 if get_pixel(base_x + 1, base_y)
          val |= 1 << 2 if get_pixel(base_x, base_y + 1)
          val |= 1 << 3 if get_pixel(base_x + 1, base_y + 1)
          val |= 1 << 4 if get_pixel(base_x, base_y + 2)
          val |= 1 << 5 if get_pixel(base_x + 1, base_y + 2)
          val |= 1 << 6 if get_pixel(base_x, base_y + 3)
          val |= 1 << 7 if get_pixel(base_x + 1, base_y + 3)

          io << OCTANTS[val]
        end
      end
      io << '\n'
    end
  end
end

struct BitmapFont
  alias Glyph = StaticArray(UInt8, 5)

  getter width : Int32
  getter height : Int32

  def initialize(@width : Int32, @height : Int32, @glyphs : Hash(Char, Glyph))
  end

  def draw(canvas : Canvas, x : Int32, y : Int32, text : String)
    cursor_x = x

    text.each_char do |char|
      glyph = @glyphs.fetch(char.upcase, @glyphs['?']?)
      draw_glyph(canvas, cursor_x, y, glyph) if glyph
      cursor_x += @width + 1
    end
  end

  private def draw_glyph(canvas : Canvas, x : Int32, y : Int32, glyph : Glyph)
    glyph.each_with_index do |row, ry|
      @width.times do |rx|
        if (row & (1_u8 << (@width - 1 - rx))) != 0
          canvas.set_pixel(x + rx, y + ry)
        end
      end
    end
  end

  def self.default
    glyphs = {
      ' ' => Glyph[0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      'A' => Glyph[2_u8, 5_u8, 7_u8, 5_u8, 5_u8],
      'B' => Glyph[6_u8, 5_u8, 6_u8, 5_u8, 6_u8],
      'C' => Glyph[3_u8, 4_u8, 4_u8, 4_u8, 3_u8],
      'D' => Glyph[6_u8, 5_u8, 5_u8, 5_u8, 6_u8],
      'E' => Glyph[7_u8, 4_u8, 7_u8, 4_u8, 7_u8],
      'F' => Glyph[7_u8, 4_u8, 7_u8, 4_u8, 4_u8],
      'G' => Glyph[3_u8, 4_u8, 5_u8, 5_u8, 3_u8],
      'H' => Glyph[5_u8, 5_u8, 7_u8, 5_u8, 5_u8],
      'I' => Glyph[7_u8, 2_u8, 2_u8, 2_u8, 7_u8],
      'J' => Glyph[1_u8, 1_u8, 1_u8, 5_u8, 3_u8],
      'K' => Glyph[5_u8, 6_u8, 4_u8, 6_u8, 5_u8],
      'L' => Glyph[4_u8, 4_u8, 4_u8, 4_u8, 7_u8],
      'M' => Glyph[5_u8, 7_u8, 7_u8, 5_u8, 5_u8],
      'N' => Glyph[6_u8, 5_u8, 5_u8, 5_u8, 5_u8],
      'O' => Glyph[2_u8, 5_u8, 5_u8, 5_u8, 2_u8],
      'P' => Glyph[6_u8, 5_u8, 6_u8, 4_u8, 4_u8],
      'Q' => Glyph[2_u8, 5_u8, 5_u8, 2_u8, 1_u8],
      'R' => Glyph[6_u8, 5_u8, 6_u8, 5_u8, 5_u8],
      'S' => Glyph[3_u8, 4_u8, 2_u8, 1_u8, 6_u8],
      'T' => Glyph[7_u8, 2_u8, 2_u8, 2_u8, 2_u8],
      'U' => Glyph[5_u8, 5_u8, 5_u8, 5_u8, 7_u8],
      'V' => Glyph[5_u8, 5_u8, 5_u8, 5_u8, 2_u8],
      'W' => Glyph[5_u8, 5_u8, 7_u8, 7_u8, 5_u8],
      'X' => Glyph[5_u8, 5_u8, 2_u8, 5_u8, 5_u8],
      'Y' => Glyph[5_u8, 5_u8, 2_u8, 2_u8, 2_u8],
      'Z' => Glyph[7_u8, 1_u8, 2_u8, 4_u8, 7_u8],
      '0' => Glyph[2_u8, 5_u8, 5_u8, 5_u8, 2_u8],
      '1' => Glyph[2_u8, 6_u8, 2_u8, 2_u8, 7_u8],
      '2' => Glyph[6_u8, 1_u8, 2_u8, 4_u8, 7_u8],
      '3' => Glyph[6_u8, 1_u8, 3_u8, 1_u8, 6_u8],
      '4' => Glyph[5_u8, 5_u8, 7_u8, 1_u8, 1_u8],
      '5' => Glyph[7_u8, 4_u8, 6_u8, 1_u8, 6_u8],
      '6' => Glyph[3_u8, 4_u8, 6_u8, 5_u8, 3_u8],
      '7' => Glyph[7_u8, 1_u8, 2_u8, 2_u8, 2_u8],
      '8' => Glyph[2_u8, 5_u8, 2_u8, 5_u8, 2_u8],
      '9' => Glyph[3_u8, 5_u8, 3_u8, 1_u8, 6_u8],
      '!' => Glyph[2_u8, 2_u8, 2_u8, 0_u8, 2_u8],
      '?' => Glyph[6_u8, 1_u8, 2_u8, 0_u8, 2_u8],
      '.' => Glyph[0_u8, 0_u8, 0_u8, 0_u8, 2_u8],
      ',' => Glyph[0_u8, 0_u8, 0_u8, 2_u8, 4_u8],
      '-' => Glyph[0_u8, 0_u8, 7_u8, 0_u8, 0_u8]
    }
    new(3, 5, glyphs)
  end
end

  canvas = Canvas.new(120, 24)
  font = BitmapFont.default

  canvas.render_mode = RenderMode::Braille
  font.draw(canvas, 2, 2, "Promon")
  font.draw(canvas, 8, 10, "BRAILLE 2D CANVAS 123-456")
  
  puts canvas
  canvas.clear

  canvas.render_mode = RenderMode::LegacyOctant
  font.draw(canvas, 2, 2, "Promon")
  font.draw(canvas, 8, 10, "OCTANT RENDERER 123-456")
  
  puts canvas