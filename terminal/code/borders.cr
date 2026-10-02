# borders.cr

module UI
  record Border,
    tl : Char,
    t  : Char,
    tr : Char,
    l  : Char,
    r  : Char,
    bl : Char,
    b  : Char,
    br : Char

  LEGACY_ROUNDED = Border.new(
    tl: '🯮',
    t:  '▂',
    tr: '🯭',
    l:  '▐',
    r:  '▌',
    bl: '🯬',
    b:  '🮂',
    br: '🯯'
  )

  SINGLE = Border.new(
    tl: '┌',
    t:  '─',
    tr: '┐',
    l:  '│',
    r:  '│',
    bl: '└',
    b:  '─',
    br: '┘'
  )

  DOUBLE = Border.new(
    tl: '╔',
    t:  '═',
    tr: '╗',
    l:  '║',
    r:  '║',
    bl: '╚',
    b:  '═',
    br: '╝'
  )

  ROUNDED = Border.new(
    tl: '╭',
    t:  '─',
    tr: '╮',
    l:  '│',
    r:  '│',
    bl: '╰',
    b:  '─',
    br: '╯'
  )

  THICK = Border.new(
    tl: '┏',
    t:  '━',
    tr: '┓',
    l:  '┃',
    r:  '┃',
    bl: '┗',
    b:  '━',
    br: '┛'
  )

  BLOCK = Border.new(
    tl: '▛',
    t:  '▀',
    tr: '▜',
    l:  '▌',
    r:  '▐',
    bl: '▙',
    b:  '▄',
    br: '▟'
  )

  BRAILLE = Border.new(
    tl: '⡊',
    t:  '⠉',
    tr: '⢑',
    l:  '⡇',
    r:  '⢸',
    bl: '⢃',
    b:  '⣀',
    br: '⡘'
  )

  def self.render_box(io : IO, text : String, row : Int32, col : Int32, width : Int32, height : Int32, border : Border = LEGACY_ROUNDED) : Nil
    return if width < 2 || height < 2

    inner_width  = width - 2
    inner_height = height - 2
    lines        = text.lines

    io << "\e[" << row << ';' << col << 'H'
    io << border.tl
    inner_width.times { io << border.t }
    io << border.tr

    inner_height.times do |i|
      io << "\e[" << (row + i + 1) << ';' << col << 'H'
      io << border.l

      line_text    = i < lines.size ? lines[i] : ""
      display_text = line_text.size > inner_width ? line_text[0...inner_width] : line_text

      io << display_text
      (inner_width - display_text.size).times { io << ' ' }

      io << border.r
    end

    io << "\e[" << (row + height - 1) << ';' << col << 'H'
    io << border.bl
    inner_width.times { io << border.b }
    io << border.br
  end

  def self.render_box(text : String, row : Int32, col : Int32, width : Int32, height : Int32, border : Border = LEGACY_ROUNDED) : String
    String.build(capacity: 256) do |io|
      render_box(io, text, row, col, width, height, border)
    end
  end
end

print "\e[2J"

UI.render_box(STDOUT, "Legacy",  2,  2, 20, 5, UI::LEGACY_ROUNDED)
UI.render_box(STDOUT, "Single",  8,  2, 20, 5, UI::SINGLE)
UI.render_box(STDOUT, "Double", 14,  2, 20, 5, UI::DOUBLE)

UI.render_box(STDOUT, "Rounded", 2, 24, 20, 5, UI::ROUNDED)
UI.render_box(STDOUT, "Thick",   8, 24, 20, 5, UI::THICK)
UI.render_box(STDOUT, "Block",  14, 24, 20, 5, UI::BLOCK)

UI.render_box(STDOUT, "Braille", 20, 2, 20, 5, UI::BRAILLE)

print "\e[27;1H"