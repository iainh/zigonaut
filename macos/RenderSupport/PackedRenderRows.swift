import ZigonautCore

/// A cheap view of one packed record. Text is decoded only at a native text API.
public struct TerminalRenderCell: Identifiable {
  public let record: zigonaut_render_cell_v1
  public let textBytes: ArraySlice<UInt8>
  private let frameBackground: UInt32

  init(record: zigonaut_render_cell_v1, textBytes: ArraySlice<UInt8>, background: UInt32) {
    self.record = record
    self.textBytes = textBytes
    frameBackground = background
  }

  public var id: UInt32 { UInt32(record.y) << 16 | UInt32(record.x) }
  public var x: Int { Int(record.x) }
  public var y: Int { Int(record.y) }
  public var text: String { String(decoding: textBytes, as: UTF8.self) }
  public var foreground: UInt32 { record.foreground_rgb }
  public var background: UInt32 { record.background_rgb }
  public var underlineColor: UInt32 { record.underline_rgb }
  public var occupancy: UInt8 { record.occupancy }
  public var underlineStyle: UInt8 { record.underline_style }
  public var bold: Bool { record.bold != 0 }
  public var italic: Bool { record.italic != 0 }
  public var faint: Bool { record.faint != 0 }
  public var strikethrough: Bool { record.strikethrough != 0 }
  public var overline: Bool { record.overline != 0 }
  public var selected: Bool { record.selected != 0 }
  public var backgroundIsDefault: Bool {
    record.background_is_default != 0 && record.background_rgb == frameBackground
  }
  public var searchHighlight: UInt8 { record.search_highlight }
}

/// Immutable, independently owned row storage. Unchanged rows share their
/// copy-on-write buffers with the preceding published snapshot.
public struct PackedRenderRow: RandomAccessCollection {
  public typealias Index = Int
  public let records: [zigonaut_render_cell_v1]
  public let textBytes: [UInt8]
  private let background: UInt32

  public init(cells: ArraySlice<zigonaut_render_cell_v1>, text: [UInt8], background: UInt32) {
    let first = Int(cells.first?.text_offset ?? 0)
    let last = cells.last.map { Int($0.text_offset) + Int($0.text_length) } ?? first
    precondition(first <= last && last <= text.count)
    var records = Array(cells)
    for index in records.indices { records[index].text_offset -= UInt32(first) }
    self.records = records
    textBytes = Array(text[first..<last])
    self.background = background
  }

  public var startIndex: Int { 0 }
  public var endIndex: Int { records.count }
  public func index(after index: Int) -> Int { index + 1 }
  public func index(before index: Int) -> Int { index - 1 }
  public subscript(index: Int) -> TerminalRenderCell {
    let cell = records[index]
    let start = Int(cell.text_offset)
    return TerminalRenderCell(record: cell,
      textBytes: textBytes[start..<(start + Int(cell.text_length))], background: background)
  }
}

/// A rectangular row view, not a flattened copy of every retained cell.
public struct TerminalRenderCells: RandomAccessCollection {
  public typealias Index = Int
  public let rows: [PackedRenderRow]
  public let columns: Int

  public init(rows: [PackedRenderRow] = [], columns: Int = 0) {
    precondition(rows.allSatisfy { $0.count == columns })
    self.rows = rows
    self.columns = columns
  }

  public var startIndex: Int { 0 }
  public var endIndex: Int { rows.count * columns }
  public func index(after index: Int) -> Int { index + 1 }
  public func index(before index: Int) -> Int { index - 1 }
  public subscript(index: Int) -> TerminalRenderCell {
    rows[index / columns][index % columns]
  }
}
