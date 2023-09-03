const std = @import("std");

// Things to do:

/// Write a type introspection tool.
/// Write a build.zig, to make a binary from this file.
///     Then you can debug this.
/// Find out why fmt_max_depth is funky (can't go too deep into my type or crash).
///     Maybe it's a bug \shrug
/// Create a function that takes .{.thing = Type1, .other_thing = Type2} and can extract
///     both the strings 'thing', 'other_thing', and the types Type1 and Type2.
///
pub const std_options = struct {
    pub const log_level = .debug;
    pub const fmt_max_depth = 3;
};

// fn type_fmt(comptime thing: anytype, tabs: usize) []const u8 {
//     _ = tabs;
//     const desc_type = @TypeOf(thing);
//     std.debug.print("\nInspecting component description : {s}\n", .{@typeName(desc_type)});
//     const desc_type_info: std.builtin.Type = @typeInfo(desc_type);
//     switch (desc_type_info) {
//         .Int => |integer| {
//             std.debug.print("integer : {{\nsignedness : {}\nbits: {}}}", .{ integer.signedness, integer.bits });
//         },
//         .Float => |float| {
//             std.debug.print("float : {}", .{float});
//         },
//         .Pointer => |pointer| {
//             std.debug.print("pointer : {}", .{pointer});
//         },
//         .Array => |array| {
//             std.debug.print("array : {}", .{array});
//         },
//         .Struct => |structure| {
//             _ = structure;
//         },
//         .Optional => |optional| {
//             _ = optional;
//         },
//         .ErrorUnion => |err| {
//             _ = err;
//         },
//         .ErrorSet => |set| {
//             _ = set;
//         },
//         .Enum => |enumer| {
//             _ = enumer;
//         },
//         .Union => |uniona| {
//             _ = uniona;
//         },
//         .Fn => |function| {
//             _ = function;
//         },
//         .Opaque => |not_clear| {
//             _ = not_clear;
//         },
//         .Frame => |frame| {
//             _ = frame;
//         },
//         .AnyFrame => |any_frame| {
//             _ = any_frame;
//         },
//         .Vector => |vector| {
//             _ = vector;
//         },
//         else => {
//             // all cases that are of type 'void'.
//         },
//     }
// }

inline fn comp_print(fmt: []const u8, args: anytype) void {
    std.debug.print("{s}", .{std.fmt.comptimePrint(fmt, args)});
}

pub fn get_slice_of(comptime components: anytype) !void {
    const desc_type = @TypeOf(components);
    const desc_type_info: std.builtin.Type = @typeInfo(desc_type);
    inline for (desc_type_info.Struct.fields) |field| {
        std.debug.print("Field info: {s}\n", .{field.name});
        std.debug.print("Field Value : {s}\n", .{@typeName(@field(components, field.name))});
    }
}

pub fn main() !void {
    const Meatbag_ahh = struct { health: usize };
    _ = Meatbag_ahh;
    const Transform = struct { position: usize };
    var thing: Transform = .{ .position = 3 };
    var ptr_thing: *Transform = &thing;
    comp_print("{}\n", .{@typeInfo(Transform)});
    std.debug.print("{}\n", .{@typeInfo(@TypeOf(ptr_thing))});
    //try get_slice_of(.{ .meatbag = Meatbag_ahh, .transform = Transform });
}
