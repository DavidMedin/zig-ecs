const std = @import("std");
const testing = std.testing;

// Is a unique id.
const Entity = ?usize;

const component_allocator = std.testing.allocator;

// TODO: Turn this struct into PackedSet
fn ComponentStorage(comptime ty: type) type {
    return struct {
        const Self = @This();

        // This array represents whether an entity has a component, and where to find it.
        // If an entry is 0, that entity doesn't have this component. Otherwise,
        // the entity's component's data is in the packed set at index i-1, where i is the
        // value in the sparse sent.
        // sparse_set: std.ArrayList(?usize),
        packed_set: std.MultiArrayList(ty),

        pub fn init(self: *Self) !void {
            // self.sparse_set = std.ArrayList(?usize).init(component_allocator);
            self.packed_set = .{};
            // try self.sparse_set.resize(alloc_count);

            // initalize all new component indicies to null.
            // for (self.sparse_set.items) |*item| {
            //     item.* = null;
            // }
        }

        pub fn deinit(self: *Self) void {
            // self.*.sparse_set.deinit();
            self.*.packed_set.deinit(component_allocator);
        }
    };
}

const ComponentStorageErased = struct {
    const Self = @This();

    ptr: *anyopaque,
    deinit: *const fn (*Self) void,
    add_one: *const fn (*Self, anytype) anyerror!void,
    len: *const fn(*Self) usize,
    // remove_component: *const fn (*Self, Entity) anyerror!void,
    make_new: *const fn (*Self, usize) anyerror!Self,

    pub fn init(comptime hidden_type: type, alloc_count: usize) !Self {
        const new_data = try component_allocator.create(ComponentStorage(hidden_type));
        try new_data.init(alloc_count);
        return Self{
            .ptr = new_data,
            .deinit = struct {
                pub fn deinit(self: *Self) void {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    hidden.deinit();
                    component_allocator.destroy(hidden);
                }
            }.deinit,
            .make_new = struct {
                pub fn make_new(self: *Self, inner_alloc_count: usize) !Self {
                    _ = self;
                    return Self.init(hidden_type, inner_alloc_count);
                }
            }.make_new,

            .add_one = struct {
               pub fn add_one(self: *Self, data : anytype) !void {
                   std.debug.assert( data == hidden_type);
                   var hidden = self.cast(hidden_type);
                   try hidden.*.packed_set.AddOne(data);
               }
            }.add_one,
            .len = struct {
                pub fn len(self : *Self) usize {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    return hidden.*.packed_set.len;
                }
            }
            // , .remove_component = struct {
            //    pub fn remove_component(self: *Self, ent: Entity) !void {
            //        var hidden = self.cast(hidden_type);
            //        return hidden.remove_component(ent);
            //    }
            //}.remove_component
        };
    }

    pub fn cast(self: *Self, comptime cast_to: type) *ComponentStorage(cast_to) {
        return @ptrCast(@alignCast(self.*.ptr));
    }
};

const Archetype = struct {
    const Self = @This();
    components: std.StringArrayHashMap(ComponentStorageErased),

    pub fn init(components: [][]const u8, component_storages: []ComponentStorageErased) Self {
        var self: Self = .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator) };
        for (components, component_storages) |component_name, component_storage| {
            self.components.put(component_name, component_storage);
        }
    }
};

const EntityInfo = struct { version: u32, archetype_idx: usize, packed_idx: usize };

const ECSError = error{ EntityMissingComponent, InvalidEntity, OldEntity };
const ECS = struct {
    entity_info: std.ArrayList(EntityInfo),
    archetypes: std.ArrayList(Archetype),
    next_entity: usize = 0,

    const Self = @This();
    pub fn init() Self {
        return Self{ //.components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator),
            .sparse_set = std.ArrayList(EntityInfo).init(component_allocator),
            .archetypes = std.ArrayList(Archetype).init(component_allocator),
        };
    }
    pub fn deinit(self: *Self) void {
        //for (self.*.components.values()) |*value| {
        //    value.*.deinit(value);
        //}
        self.*.archetypes.deinit();
        self.*.components.deinit();
        self.*.sparse_set.deinit();
    }

    pub fn new_entity(self: *Self) !Entity {
        self.*.next_entity += 1;

        // Add a new component slot for every component type.
        //for (self.*.components.values()) |*value| {
        //    try value.*.add_one(value);
        //}
        var new_info: *EntityInfo = self.*.entity_info.addOne();
        // TODO: fix me.
        _ = new_info;
        return self.*.next_entity - 1;
    }

    pub fn add_component(self: *Self, entity: Entity, component_name: []const u8, comp_t: anytype) !void {
        // Unwrap entity.
        const safe_entity: usize = entity orelse return ECSError.InvalidEntity;
        // Query the sparse set to see what archetype this entity is in (and its index).
        const ent_info: EntityInfo = self.*.entity_info.items[safe_entity];
        const arch: *Archetype = self.*.archetypes[ent_info.archetype_idx];

        // These are the components that this entity currently has.
        const arch_component_names: [][]const u8 = arch.*.components.keys();

        // assert that component_name is not in arch_components.
        std.debug.assert(for (arch_component_names) |component| {
            if (std.mem.eql(u8, component == component_name)) {
                break false;
            }
        } else {
            true;
        });

        // Try to find an archetype that has arch_components and component_name.
        var matching_arch: ?usize = outer: for (0.., self.*.archetypes) |arch_idx, *archetype| {
            for (arch_component_names) |component| {
                if (!archetype.*.components.contains(component)) {
                    // This archetype does not match.
                    continue :outer;
                }
            }
            if (archetype.*.components.contains(component_name)) {
                // This archetype matches! Use this one.
                // This matches both the previous for loop and now this if statement.
                break arch_idx;
            }
        } else {
            null;
        };

        // If there is no archetype that has the required components, make a new one that does!
        if (matching_arch == null) {
            // This means there are no archetypes that exist for this list of components; we must make one.

            // Use the current archetype's ComponentStorageErased to create a new set of those components types
            const old_arch_component_types: []ComponentStorageErased = arch.*.components.values();
            const arch_component_types: []ComponentStorageErased = [arch_component_names.len + 1]ComponentStorageErased{};
            // write to the new ComponentStorages
            for (old_arch_component_types, arch_component_types) |*component_storage, *new_component_storage| {
                new_component_storage.* = component_storage.make_new(self.*.next_entity);
            }
            arch_component_types[arch_component_names.len] = ComponentStorageErased.init(comp_t, self.*.next_entity);

            var new_components = [][arch_component_names.len + 1]u8{0};
            std.mem.copyForwards(u8, new_components[0..new_components.len], arch_component_names);
            new_components[new_components.len - 1] = component_name;
            // TODO: Create new_archetype(list of strings)

            try self.archetypes.addOne(Archetype.init(new_components, arch_component_types));
            matching_arch = self.archetypes.items.len - 1;
        }

        const to_archetype : *Archetype = &self.*.archetypes[matching_arch.?];
        to_archetype.components[component_name].add_one(comp_t);
        self.*.archetypes[self.entity_info[safe_entity].?.archetype_idx]. # TODO
        self.entity_info[safe_entity] = EntityInfo{.archetype_idx = matching_arch, .packed_idx = to_archetype.components[component_name].len()};
    }
};

test "ECS declaration" {
    const meatbag = struct { health: u32, something_else: i64 };
    const vec2 = struct { x: f32, y: f32 };
    const transform = struct { position: vec2, rotation: f32, velocity: vec2 };

    var world = ECS.init();
    defer world.deinit();

    const player_ent = try world.new_entity();
    try world.add_component(player_ent, "meatbag", meatbag{ .health = 2, .something_else = 123 });
    try world.add_component(player_ent, "transform", transform{ .position = .{ .x = 2, .y = 1 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 0 } });

    const enemy_ent = try world.new_entity();
    _ = enemy_ent;

    var player_comp: meatbag = (try world.get_component(player_ent, "meatbag", meatbag)).?;
    std.debug.print("{}\n", .{player_comp});
}

test "Remove Component" {
    const Name = struct { name: []u8 };

    var world = ECS.init();
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "name", Name{ .name = @constCast("Jim") });
    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "name", Name{ .name = @constCast("Julia") });
    const entity_3 = try world.new_entity();
    try world.add_component(entity_3, "name", Name{ .name = @constCast("Alexa") });

    try world.remove_component(entity_1, "name");
    std.debug.assert((try world.get_component(entity_1, "name", Name)) == null);
    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_2, "name", Name)).?.name, @constCast("Julia")));
    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_3, "name", Name)).?.name, @constCast("Alexa")));
}

test "Writing Components" {
    const Name = struct { name: []u8 };

    var world = ECS.init();
    defer world.deinit();

    const clutter_ent_1 = try world.new_entity();
    try world.add_component(clutter_ent_1, "name", Name{ .name = @constCast("Aleric") });

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "name", Name{ .name = @constCast("Jessica") });
    const clutter_ent_2 = try world.new_entity();
    try world.add_component(clutter_ent_2, "name", Name{ .name = @constCast("Isabella") });

    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.name, @constCast("Jessica")));

    try world.write_component(entity_1, "name", Name{ .name = @constCast("Rose") });

    std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.name, @constCast("Rose")));
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

    var world = ECS.init();
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "meatbag", Meatbag{ .health = 42, .armor = 4 });
    try world.add_component(entity_1, "transform", Transform{ .position = .{ .x = 1, .y = 1 } });
    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "meatbag", Meatbag{ .health = 99, .armor = 8 });
    try world.add_component(entity_2, "transform", Transform{ .position = .{ .x = -1, .y = -1 } });

    var meatbag_slice = world.get_slice_of("meatbag", Meatbag);
    var transform_slice = world.get_slie_of("transform", Transform);
    for (meatbag_slice.items(.health), meatbag_slice.items(.armor), transform_slice.items(.position)) |*health, armor, *position| {
        _ = position;
        _ = armor;
        _ = health;
    }
}
