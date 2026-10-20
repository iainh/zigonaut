import Testing
import ZigonautCore
import ZigonautRenderSupport

@Test func packedRowsOwnRebasedUnicodeAndRetainUnchangedRows() {
  var text = Array("prefix界é😀".utf8)
  var records = [zigonaut_render_cell_v1](repeating: .init(), count: 3)
  for index in records.indices {
    records[index].x = UInt16(index)
    records[index].y = 2
    records[index].background_rgb = 0x123456
    records[index].background_is_default = 1
  }
  records[0].text_offset = 6; records[0].text_length = 3; records[0].occupancy = 1
  records[1].text_offset = 9; records[1].text_length = 3; records[1].selected = 1
  records[2].text_offset = 12; records[2].text_length = 4
  let original = PackedRenderRow(cells: records[...], text: text, background: 0x123456)
  text = []
  records[0].text_offset = 0
  #expect(original.map(\.text) == ["界", "é", "😀"])
  #expect(original[0].occupancy == 1)
  #expect(original[0].backgroundIsDefault)
  #expect(original[1].selected)
  let earlier = TerminalRenderCells(rows: [original, original], columns: 3)
  var changed = Array("abc".utf8)
  for index in records.indices {
    records[index].text_offset = UInt32(index)
    records[index].text_length = 1
    records[index].y = 3
  }
  let replacement = PackedRenderRow(cells: records[...], text: changed, background: 0)
  changed = []
  let later = TerminalRenderCells(rows: [original, replacement], columns: 3)
  #expect(earlier.map(\.text) == ["界", "é", "😀", "界", "é", "😀"])
  #expect(later.map(\.text) == ["界", "é", "😀", "a", "b", "c"])
  #expect(later[3].y == 3)
  #expect(!later[3].backgroundIsDefault)
  #expect(TerminalRenderCells().isEmpty)
}
