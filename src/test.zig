const std = @import("std");
const testing = std.testing;

test "arrays are hard" {
    var thing : std.StringArrayHashMap(i64) = std.StringArrayHashMap(i64).init(std.testing.allocator);
    defer thing.deinit();
    try thing.put("help", 2);
    try thing.put("please_help", 42);
    
    const keys : [][]const u8 = thing.keys();
    for(keys) |key|{
        std.debug.print("{s}\n", .{key});
    }
    //const thing_i_cant_do : [][]const u8 = [keys.len]u8{};
    const new_keys : [][]const u8 = try std.testing.allocator.alloc([]const u8, keys.len + 1);
    defer std.testing.allocator.free(new_keys);
    
    std.mem.copyForwards([]const u8, new_keys[0..new_keys.len], keys);
    new_keys[new_keys.len - 1] = "yo mama";

    std.debug.print("New shit: \n",.{});
    for(new_keys) |key|{
        std.debug.print("{s}\n", .{key});
    }
}