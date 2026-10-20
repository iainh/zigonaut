const std = @import("std");

pub const Span = extern struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
    colour: u32,
};

pub export fn zigonaut_background_span_extend(span: *Span, next: *const Span) u8 {
    if (span.colour != next.colour or span.right != next.left or
        span.top != next.top or span.bottom != next.bottom) return 0;
    span.right = next.right;
    return 1;
}

test "background spans join wide cells but not gaps, colours, rows or heights" {
    var span = Span{ .left = 3.5, .top = 7, .right = 12.5, .bottom = 24, .colour = 0x123456 };
    var next = Span{ .left = 12.5, .top = 7, .right = 30.5, .bottom = 24, .colour = 0x123456 };
    try std.testing.expectEqual(@as(u8, 1), zigonaut_background_span_extend(&span, &next));
    try std.testing.expectEqual(@as(f64, 30.5), span.right);
    const joined = span;
    next.left = 31;
    try std.testing.expectEqual(@as(u8, 0), zigonaut_background_span_extend(&span, &next));
    next.left = 30.5;
    next.colour = 0x654321;
    try std.testing.expectEqual(@as(u8, 0), zigonaut_background_span_extend(&span, &next));
    next.colour = span.colour;
    next.top = 24;
    try std.testing.expectEqual(@as(u8, 0), zigonaut_background_span_extend(&span, &next));
    next.top = span.top;
    next.bottom = 25;
    try std.testing.expectEqual(@as(u8, 0), zigonaut_background_span_extend(&span, &next));
    try std.testing.expectEqualDeep(joined, span);
}
