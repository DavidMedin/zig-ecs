const std = @import("std");

test "ahh" {
    const types = []type{ u64, i32 };
    const HelpMe = struct {
        usingnamespace inline for (types) |type_| {
            var ahhh: type_ = undefined;
            _ = ahhh;
        };
    };
    var please: HelpMe = undefined;
    std.debug.log("{}\n", .{please.ahhh});
}
