const std = @import("std");
const testing = std.testing;

const ecs = @import("ecs.zig");

test "ECS declaration" {
    const meatbag = struct { health: u32, something_else: i64 };
    const vec2 = struct { x: f32, y: f32 };
    const transform = struct { position: vec2, rotation: f32, velocity: vec2 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const player_ent = try world.new_entity();
    try world.add_component(player_ent, "meatbag", meatbag{ .health = 2, .something_else = 123 });
    try world.add_component(player_ent, "transform", transform{ .position = .{ .x = 2, .y = 1 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 0 } });

    const enemy_ent = try world.new_entity();
    _ = enemy_ent;

    var player_comp: meatbag = (try world.get_component(player_ent, "meatbag", meatbag)).?.*;
    std.debug.print("{}\n", .{player_comp});
}

test "Complex Archetypes" {
    const meatbag = struct { health: u32, something_else: i64 };
    const vec2 = struct { x: f32, y: f32 };
    const transform = struct { position: vec2, rotation: f32, velocity: vec2 };
    const type2 = struct { member_1: i32 };
    const type3 = struct { member_1: f32 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const ent1 = try world.new_entity();
    try world.add_component(ent1, "meatbag", meatbag{ .health = 2, .something_else = 123 });
    try world.add_component(ent1, "transform", transform{ .position = .{ .x = 2, .y = 1 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 0 } });

    const ent2 = try world.new_entity();
    try world.add_component(ent2, "type2", type2{ .member_1 = 3 });
    try world.add_component(ent2, "type3", type3{ .member_1 = 3.3 });

    world.print_info();
    const ent3 = try world.new_entity(); // in the same archetype as ent1
    try world.add_component(ent3, "meatbag", meatbag{ .health = 10, .something_else = 123 });
    try world.add_component(ent3, "transform", transform{ .position = .{ .x = 4, .y = 1 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 1 } });

    const ent4 = try world.new_entity();
    try world.add_component(ent4, "type2", type2{ .member_1 = 3 });
    try world.add_component(ent4, "type3", type3{ .member_1 = 3.3 });
    try world.add_component(ent4, "transform", transform{ .position = .{ .x = 4, .y = 10 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 1 } });

    var player_comp: meatbag = (try world.get_component(ent1, "meatbag", meatbag)).?.*;
    _ = player_comp;
    _ = (try world.get_component(ent1, "transform", transform)).?.*;
    _ = (try world.get_component(ent2, "type2", type2)).?.*;
    _ = (try world.get_component(ent2, "type3", type3)).?.*;
    _ = (try world.get_component(ent3, "meatbag", meatbag)).?.*;
    _ = (try world.get_component(ent3, "transform", transform)).?.*;
    _ = (try world.get_component(ent4, "type2", type2)).?.*;
    _ = (try world.get_component(ent4, "type3", type3)).?.*;
    _ = (try world.get_component(ent4, "transform", transform)).?.*;
}

test "Remove Component" {
    const Name = struct { name: []u8 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "name", Name{ .name = @constCast("Jim") });
    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "name", Name{ .name = @constCast("Julia") });
    const entity_3 = try world.new_entity();
    try world.add_component(entity_3, "name", Name{ .name = @constCast("Alexa") });

    try world.remove_component(entity_1, "name");
    std.debug.assert((try world.get_component(entity_1, "name", Name)) == null);
    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_2, "name", Name)).?.*.name, @constCast("Julia")));
    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_3, "name", Name)).?.*.name, @constCast("Alexa")));
}

test "Writing Components" {
    const Name = struct { name: []u8 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const clutter_ent_1 = try world.new_entity();
    try world.add_component(clutter_ent_1, "name", Name{ .name = @constCast("Aleric") });

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "name", Name{ .name = @constCast("Jessica") });
    const clutter_ent_2 = try world.new_entity();
    try world.add_component(clutter_ent_2, "name", Name{ .name = @constCast("Isabella") });

    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.*.name, @constCast("Jessica")));

    try world.write_component(entity_1, "name", Name{ .name = @constCast("Rose") });

    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.*.name, @constCast("Rose")));
}

test "Slicing Component" {
    const Meatbag = struct { health: u32, armor: u32 };
    const Vec2 = struct { x: f32, y: f32 };
    const Distance: *const fn (Vec2, Vec2) f32 = struct {
        pub fn d(pnt1: Vec2, pnt2: Vec2) f32 {
            return std.math.sqrt(std.math.pow(f32, pnt1.x - pnt2.x, 2) + std.math.pow(f32, pnt1.y - pnt2.y, 2));
        }
    }.d;
    _ = Distance;
    const Transform = struct { position: Vec2 };
    const MoreData = struct { x: f32, ads: usize };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const entity_1: ecs.Entity = try world.new_entity();
    try world.add_component(entity_1, "meatbag", Meatbag{ .health = 42, .armor = 4 });
    try world.add_component(entity_1, "transform", Transform{ .position = .{ .x = 1, .y = 1 } });

    const entity_3 = try world.new_entity();
    try world.add_component(entity_3, "moreData", MoreData{ .x = 3.2, .ads = 32 });

    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "meatbag", Meatbag{ .health = 99, .armor = 8 });
    try world.add_component(entity_2, "transform", Transform{ .position = .{ .x = -1, .y = -1 } });

    var iter = ecs.data_iter(.{ .meatbag = Meatbag, .transform = Transform }).init(&world);

    var slice = iter.next();
    std.debug.assert(slice != null);
    std.debug.assert(slice.?.meatbag == (try world.get_component(entity_1, "meatbag", Meatbag)).?);
    std.debug.assert(slice.?.transform == (try world.get_component(entity_1, "transform", Transform)).?);
    std.debug.assert(@TypeOf(slice.?.entity) == ecs.Entity);
    std.debug.assert(std.meta.eql(slice.?.entity, entity_1));
    slice = iter.next();
    std.debug.assert(slice.?.meatbag == (try world.get_component(entity_2, "meatbag", Meatbag)).?);
    std.debug.assert(slice.?.transform == (try world.get_component(entity_2, "transform", Transform)).?);
    std.debug.assert(std.meta.eql(slice.?.entity, entity_2));
    slice = iter.next();
    std.debug.assert(slice == null);
}

test "Complex Slicing" {
    const Meatbag = struct { health: u32, armor: u32 };
    const Vec2 = struct { x: f32, y: f32 };
    const Distance: *const fn (Vec2, Vec2) f32 = struct {
        pub fn d(pnt1: Vec2, pnt2: Vec2) f32 {
            return std.math.sqrt(std.math.pow(f32, pnt1.x - pnt2.x, 2) + std.math.pow(f32, pnt1.y - pnt2.y, 2));
        }
    }.d;
    _ = Distance;
    const Transform = struct { position: Vec2 };
    const MoreData = struct { x: f32, ads: usize };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "meatbag", Meatbag{ .health = 42, .armor = 4 });
    try world.add_component(entity_1, "transform", Transform{ .position = .{ .x = 1, .y = 1 } });

    const entity_3 = try world.new_entity();
    try world.add_component(entity_3, "moreData", MoreData{ .x = 3.2, .ads = 32 });

    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "meatbag", Meatbag{ .health = 99, .armor = 8 });
    try world.add_component(entity_2, "transform", Transform{ .position = .{ .x = -1, .y = -1 } });
    try world.add_component(entity_2, "moreData", MoreData{ .x = 8.8, .ads = 42 });

    var iter = ecs.data_iter(.{ .meatbag = Meatbag, .transform = Transform }).init(&world);

    var slice = iter.next();
    std.debug.assert(slice != null);
    std.debug.assert(slice.?.meatbag == (try world.get_component(entity_1, "meatbag", Meatbag)).?);
    std.debug.assert(slice.?.transform == (try world.get_component(entity_1, "transform", Transform)).?);
    slice = iter.next();
    std.debug.assert(slice.?.meatbag == (try world.get_component(entity_2, "meatbag", Meatbag)).?);
    std.debug.assert(slice.?.transform == (try world.get_component(entity_2, "transform", Transform)).?);
    slice = iter.next();
    std.debug.assert(slice == null);
}

// This next test was breaking the Playdate Simulator. I don't know why. Maybe it's the ECS, hence this test.
// Now I know. It had nothing to do with the ECS but instead how I made the allocator in that project. No worries here!
test "Funky Playdate Breaker" {
    const Brain = struct { reaction_time: u64, body: ecs.Entity };
    const Controls = struct {
        const Self = @This();
        pressed_this_frame: bool = false,
        movement: i32,
    };
    const Body = struct { brain: ecs.Entity };
    const Image = struct {
        const Self = @This();
        bitmap: *anyopaque,
    };
    const Transform = struct { x: i32, y: i32 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    var fake_data: i32 = 42;
    {
        // Brain entity
        const player_brain: ecs.Entity = try world.new_entity();
        try world.add_component(player_brain, "brain", Brain{ .reaction_time = 1, .body = undefined });
        try world.add_component(player_brain, "controls", Controls{ .movement = 0 });
        var brain_component: *Brain = (try world.get_component(player_brain, "brain", Brain)).?;

        // Body entity
        const player_body: ecs.Entity = try world.new_entity();
        brain_component.*.body = player_body; // Linking the body to the brain
        try world.add_component(player_body, "body", Body{ .brain = player_brain });

        try world.add_component(player_body, "image", Image{ .bitmap = &fake_data });
        try world.add_component(player_body, "transform", Transform{ .x = 4, .y = 4 });
    }

    {
        // Create enemy
        const enemy_brain: ecs.Entity = try world.new_entity();
        try world.add_component(enemy_brain, "brain", Brain{ .reaction_time = 2, .body = undefined });
        try world.add_component(enemy_brain, "controls", Controls{ .movement = 0 });
        var enemy_brain_component: *Brain = (try world.get_component(enemy_brain, "brain", Brain)).?;

        //     // Body entity
        const enemy_body: ecs.Entity = try world.new_entity();
        enemy_brain_component.*.body = enemy_body; // Linking the body to the brain
        try world.add_component(enemy_body, "body", Body{ .brain = enemy_brain });

        try world.add_component(enemy_body, "image", Image{ .bitmap = &fake_data });
        try world.add_component(enemy_body, "transform", Transform{ .x = 4, .y = 6 });
    }

    {
        var move_iter = ecs.data_iter(.{ .controls = Controls, .brain = Brain }).init(&world);
        while (move_iter.next()) |slice| {
            // controls.update_movement(&ctx.*.world, ctx, slice.controls, slice.brain);
            slice.controls.*.movement = 0;
        }
    }

    {
        // Iterate through all 'Controllable's.
        var move_iter = ecs.data_iter(.{ .controls = Controls }).init(&world);
        while (move_iter.next()) |slice| {
            slice.controls.*.movement = 2;
            // controls.update_controls(playdate, slice.controls);

        }
    }
}

test "Simple Kill Entity" {
    const Thing = struct { aight: i32 };
    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const ent_1: ecs.Entity = try world.new_entity();
    try world.add_component(ent_1, "thing", Thing{ .aight = 2 });
    std.debug.assert(ent_1.?.version == 0);
    std.debug.assert(ent_1.?.entity_id == 0);
    try world.kill_entity(ent_1);
    const attempt_ret = world.get_component(ent_1, "thing", Thing);
    std.debug.assert(attempt_ret == ecs.ECSError.OldEntity);

    const new_ent_1: ecs.Entity = try world.new_entity();
    std.debug.assert(new_ent_1.?.entity_id == 0);
    std.debug.assert(new_ent_1.?.version == 1);
}

test "More Compelx Kill Entity" {
    const Thing = struct { aight: i32 };
    const OtherThing = struct { aahh: u32 };
    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const ent_1: ecs.Entity = try world.new_entity();
    const ent_2: ecs.Entity = try world.new_entity();
    const ent_3: ecs.Entity = try world.new_entity();
    try world.add_component(ent_1, "thing", Thing{ .aight = 2 });
    std.debug.assert(ent_1.?.version == 0);
    std.debug.assert(ent_1.?.entity_id == 0);

    try world.add_component(ent_2, "thing", Thing{ .aight = 2 });
    std.debug.assert(ent_2.?.version == 0);
    std.debug.assert(ent_2.?.entity_id == 1);

    try world.add_component(ent_3, "thing", Thing{ .aight = 2 });
    std.debug.assert(ent_3.?.version == 0);
    std.debug.assert(ent_3.?.entity_id == 2);

    try world.add_component(ent_2, "other-thing", OtherThing{ .aahh = 53 });
    _ = (try world.get_component(ent_2, "other-thing", OtherThing)).?;

    try world.kill_entity(ent_2);
    {
        const attempt_ret = world.get_component(ent_2, "thing", Thing);
        std.debug.assert(attempt_ret == ecs.ECSError.OldEntity);
    }
    {
        const attempt_ret = world.get_component(ent_2, "other-thing", OtherThing);
        std.debug.assert(attempt_ret == ecs.ECSError.OldEntity);
    }

    const new_ent_2: ecs.Entity = try world.new_entity();
    std.debug.assert(new_ent_2.?.entity_id == 1);
    std.debug.assert(new_ent_2.?.version == 1);
}

test "Simple Remove Component" {
    const Thing = struct { aight: i32 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const ent_1: ecs.Entity = try world.new_entity();
    const ent_2: ecs.Entity = try world.new_entity();
    try world.add_component(ent_1, "thing", Thing{ .aight = 2 });
    try world.add_component(ent_2, "thing", Thing{ .aight = 4 });
    std.debug.assert(ent_1.?.version == 0);
    std.debug.assert(ent_1.?.entity_id == 0);
    const ent2_thing_before = try world.get_component(ent_2, "thing", Thing);

    try world.remove_component(ent_1, "thing");
    const attempt_ret = try world.get_component(ent_1, "thing", Thing);
    std.debug.assert(attempt_ret == null);
    const ent2_thing_after = try world.get_component(ent_2, "thing", Thing);
    std.debug.assert(ent2_thing_after.?.*.aight == 4);
    std.debug.assert(@intFromPtr(ent2_thing_before) != @intFromPtr(ent2_thing_after));
}

test "Complex Remove Component" {
    const Thing = struct { aight: i32 };
    const OtherThing = struct { aahh: u32 };

    var alloc_type = std.heap.GeneralPurposeAllocator(.{}){};
    const ecs_config = ecs.ECSConfig{ .component_allocator = alloc_type.allocator() };
    var world = try ecs.ECS.init(ecs_config);
    defer world.deinit();

    const ent_1: ecs.Entity = try world.new_entity();
    std.debug.assert(ent_1.?.version == 0);
    std.debug.assert(ent_1.?.entity_id == 0);
    const ent_2: ecs.Entity = try world.new_entity();
    const ent_3: ecs.Entity = try world.new_entity();
    const ent_4: ecs.Entity = try world.new_entity();
    try world.add_component(ent_1, "thing", Thing{ .aight = 2 });
    try world.add_component(ent_2, "thing", Thing{ .aight = 53 });
    try world.add_component(ent_3, "thing", Thing{ .aight = -1 });
    try world.add_component(ent_4, "thing", Thing{ .aight = 8 });
    try world.add_component(ent_1, "other-thing", OtherThing{ .aahh = 85 });
    try world.add_component(ent_3, "other-thing", OtherThing{ .aahh = 123 });
    try world.add_component(ent_4, "other-thing", OtherThing{ .aahh = 5 });
    std.debug.assert((try world.get_component(ent_4, "other-thing", OtherThing)).?.*.aahh == 5);

    try world.remove_component(ent_1, "other-thing");
    std.debug.assert((try world.get_component(ent_1, "thing", Thing)).?.*.aight == 2);
    std.debug.assert((try world.get_component(ent_1, "other-thing", OtherThing)) == null);

    std.debug.assert((try world.get_component(ent_4, "thing", Thing)).?.*.aight == 8);
    const why = (try world.get_component(ent_4, "other-thing", OtherThing));
    _ = why;
    std.debug.assert((try world.get_component(ent_4, "other-thing", OtherThing)).?.*.aahh == 5);

    std.debug.assert((try world.get_component(ent_3, "thing", Thing)).?.*.aight == -1);
    std.debug.assert((try world.get_component(ent_3, "other-thing", OtherThing)).?.*.aahh == 123);

    std.debug.assert((try world.get_component(ent_2, "thing", Thing)).?.*.aight == 2);
    std.debug.assert((try world.get_component(ent_2, "other-thing", OtherThing)) == null);
}
