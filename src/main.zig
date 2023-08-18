const std = @import("std");
const testing = std.testing;

// Is a unique id.
const RawEntity = struct { entity_id: usize, version: usize };
const Entity = ?RawEntity;

const component_allocator = std.testing.allocator;

// TODO: Store the entity information right next to the component.
fn ComponentStorage(comptime ty: type) type {
    return struct {
        const Self = @This();

        packed_set: std.MultiArrayList(ty),

        pub fn init(self: *Self) !void {
            self.packed_set = .{};
        }

        pub fn deinit(self: *Self) void {
            self.*.packed_set.deinit(component_allocator);
        }
    };
}

const ComponentStorageErased = struct {
    const Self = @This();

    ptr: *anyopaque,
    deinit: *const fn (*Self) void,
    //add_one: *const fn (*Self, anytype) anyerror!void,
    len: *const fn (*Self) usize,
    // remove_component: *const fn (*Self, Entity) anyerror!void,
    make_new: *const fn (*Self) anyerror!Self,
    take_from: *const fn (*Self, *ComponentStorageErased, usize) anyerror!void,

    pub fn init(comptime hidden_type: type) !Self {
        const new_data = try component_allocator.create(ComponentStorage(hidden_type));
        try new_data.init();

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
                pub fn make_new(self: *Self) !Self {
                    _ = self;
                    return Self.init(hidden_type);
                }
            }.make_new,

            //.add_one = struct {
            //   pub fn add_one(self: *Self, data : anytype) !void {
            //       std.debug.assert( @TypeOf(data) == hidden_type);
            //       var hidden = self.cast(hidden_type);
            //       try hidden.*.packed_set.AddOne(data);
            //   }
            //}.add_one,
            .len = struct {
                pub fn len(self: *Self) usize {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    return hidden.*.packed_set.len;
                }
            }.len,

            .take_from = struct {
                // This function will take the component from 'take_from_this' at index 'from_index' and move it to
                // self's end. Note, this does not know what an 'ECS' is, and will not adjust the Grand Sparse Set.
                pub fn take_from(self: *Self, take_from_this: *ComponentStorageErased, from_index: usize) anyerror!void {
                    var hidden_self: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    var hidden_from: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(take_from_this.*.ptr));

                    // copy the value
                    const moving_value: hidden_type = hidden_from.*.packed_set.get(from_index);
                    //Remove the value
                    hidden_from.*.packed_set.swapRemove(from_index);
                    //write the value to the other component storage.
                    try hidden_self.*.packed_set.append(component_allocator, moving_value);
                }
            }.take_from,
        };
    }

    pub fn cast(self: *Self, comptime cast_to: type) *ComponentStorage(cast_to) {
        return @ptrCast(@alignCast(self.*.ptr));
    }
};

// An archetype is a collection of Component Storages. Each archetype store the components of entities
// that all have exactly the same components.
// There is also an 'Emtpy Archetype', which all entities that have no components are in. This archetype will always
// exist. In the ECS, it will always be the first archetype.
const Archetype = struct {
    const Self = @This();
    components: std.StringArrayHashMap(ComponentStorageErased),
    len: usize, // TODO: Implement this.

    pub fn init(components: [][]const u8, component_storages: []ComponentStorageErased) !Self {
        var self: Self = .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .len = 0 };
        for (components, component_storages) |component_name, component_storage| {
            try self.components.put(component_name, component_storage);
        }
        return self;
    }

    // This function will create a new 'Empty Archetype'
    pub fn init_empty() Self {
        return .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .len = 0 };
    }
};

// This is information about the current entity. =====

// This defines what data this entity has if it is alive.
const EntityArche = union(enum) {
    Dead,
    Alive: struct { archetype_idx: usize, packed_idx: ?usize }, // The packed_idx is optional because if is in the 'Empty Archetype' it doesn't have an index.
};

const EntityInfo = struct { version: u32, state: EntityArche };

// =======================================================

const ECSError = error{ EntityMissingComponent, InvalidEntity, OldEntity, DeadEntity };
const ECS = struct {
    entity_info: std.ArrayList(EntityInfo),
    archetypes: std.ArrayList(Archetype),
    next_entity: usize = 0,

    const Self = @This();
    pub fn init() !Self {
        var archetypes = std.ArrayList(Archetype).init(component_allocator);
        try archetypes.append( Archetype.init_empty() );
        return Self{ //.components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator),
            //.sparse_set = std.ArrayList(EntityInfo).init(component_allocator),
            .entity_info = std.ArrayList(EntityInfo).init(component_allocator),
            .archetypes = archetypes, 
            .next_entity = 0,
        };
    }
    pub fn deinit(self: *Self) void {
        self.*.archetypes.deinit();
        self.*.entity_info.deinit();
        //self.*.components.deinit();
        //self.*.sparse_set.deinit();
    }

    pub fn new_entity(self: *Self) !Entity {
        self.*.next_entity += 1;

        var new_info: *EntityInfo = try self.*.entity_info.addOne();
        new_info.*.version = 0;
        new_info.*.state = .{ .Alive = .{ .archetype_idx = 0, .packed_idx = null } };
        return .{ .entity_id = self.*.next_entity - 1, .version = 0 };
    }

    // This function will return the RawEntity an Entity is hiding.
    // This function will error if the entity is invalid in any way.
    pub inline fn check_entity(self: *Self, entity: Entity) ECSError!void {
        const safe_entity: RawEntity = entity orelse return ECSError.InvalidEntity;
        if (safe_entity.version != self.*.entity_info.items[safe_entity.entity_id].version) {
            return ECSError.OldEntity;
        }
        if (self.*.entity_info.items[safe_entity.entity_id].state == EntityArche.Dead) {
            return ECSError.DeadEntity;
        }
    }

    pub inline fn unwrap_entity(self: *Self, entity: Entity) !usize {
        try self.*.check_entity(entity);
        return entity.?.entity_id;
    }

    // Move an entity from one archetype to another. Obviously, this can be dangerous.
    fn move_entity(self: *Self, entity: Entity, from_index: usize, to_index: usize) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);

        // TODO: add asserts that garuntee that the 'to' archetype has at least the components from the 'from' archetype.

        // Incompletely remove component from entity.
        // This will only remove the component
        var from: *Archetype = &self.*.archetypes.items[from_index];
        var to: *Archetype = &self.*.archetypes.items[to_index];

        var map_iter = from.*.components.iterator();
        while (map_iter.next()) |item| {
            const key = item.key_ptr.*;
            const value: *ComponentStorageErased = item.value_ptr;
            // We can assume now that we will never come across the 'Emtpy Archetype' here.
            var to_component_storage: *ComponentStorageErased = to.*.components.getPtr(key).?;

            // This way we know where the last item of the 'from' archetype went.
            const entity_index: usize = self.*.entity_info.items[safe_entity].state.Alive.packed_idx.?;

            try to_component_storage.*.take_from(to_component_storage,value, entity_index);
            // We know that all of this data will be put at the end of to_component_storage.
            // Now update the sparse set and stuff!
            self.*.entity_info.items[safe_entity].state.Alive.archetype_idx = to_index;
            self.*.entity_info.items[safe_entity].state.Alive.packed_idx = to_component_storage.*.len(to_component_storage) - 1;

            // TODO: Get rid of this garbage. Store the entity information right next to each component.
            for (self.*.entity_info.items) |*entity_info| {
                switch (entity_info.*.state) {
                    .Alive => |*arche_info| {
                        // If this entity is alive, check it...
                        if (arche_info.*.packed_idx == from_index and arche_info.*.packed_idx.? == entity_index) {
                            arche_info.*.packed_idx = entity_index;
                            break;
                        }
                    },
                    .Dead => {
                        continue;
                    },
                }
            } else { // This runs when 'break' is not hit.
                unreachable;
            }
        }
    }

    pub fn add_component(self: *Self, entity: Entity, component_name: []const u8, comp_t: anytype) !void {
        // Unwrap entity.
        const safe_entity: usize = try self.*.unwrap_entity(entity);

        // Query the sparse set to see what archetype this entity is in (and its index).
        const ent_info: EntityInfo = self.*.entity_info.items[safe_entity];
        const arch: *Archetype = &self.*.archetypes.items[ent_info.state.Alive.archetype_idx];

        // These are the components that this entity currently has.
        const arch_component_names: [][]const u8 = arch.*.components.keys();

        // assert that component_name is not in arch_components.
        std.debug.assert(for (arch_component_names) |component| {
            if (std.mem.eql(u8, component, component_name)) {
                break false;
            }
        } else blk: {
            break :blk true;
        });

        // Try to find an archetype that has arch_components and component_name.
        var matching_arch: ?usize = outer: for (0.., self.*.archetypes.items) |arch_idx, *archetype| {
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
        } else blk: {
            break :blk null;
        };

        // If there is no archetype that has the required components, make a new one that does!
        if (matching_arch == null) {
            // This means there are no archetypes that exist for this list of components; we must make one.

            // Use the current archetype's ComponentStorageErased to create a new set of those components types
            const old_arch_component_types: []ComponentStorageErased = arch.*.components.values();
            const arch_component_types: []ComponentStorageErased = try component_allocator.alloc(ComponentStorageErased, arch_component_names.len + 1);//[arch_component_names.len + 1]ComponentStorageErased{};
            defer component_allocator.free(arch_component_types);
            // write to the new ComponentStorages
            for (old_arch_component_types, arch_component_types[0..arch_component_types.len-1]) |*component_storage, *new_component_storage| {
                new_component_storage.* = try component_storage.*.make_new(component_storage);
            }
            arch_component_types[arch_component_names.len] = try ComponentStorageErased.init(@TypeOf(comp_t));// , self.*.next_entity

            var new_components = try component_allocator.alloc([]const u8, arch_component_names.len + 1);//[][arch_component_names.len + 1]u8{0};
            defer component_allocator.free(new_components);

            std.mem.copyForwards([]const u8, new_components[0..new_components.len], arch_component_names);
            new_components[arch_component_names.len] = component_name;

            try self.archetypes.append(try Archetype.init(new_components, arch_component_types));
            matching_arch = self.archetypes.items.len - 1;
        }
        std.debug.assert(matching_arch != null);

        const to_archetype: *Archetype = &self.*.archetypes.items[matching_arch.?];
        _ = to_archetype;

        try self.move_entity(entity, ent_info.state.Alive.archetype_idx, matching_arch.?);

        //// Add new component to the new component
        //const getorput_result = to_archetype.components.getOrPut(component_name);
        //std.debug.assert(getorput_result.found_existing == false);
        //getorput_result.value_ptr.* = comp_t;

        // Add this entity to the new archetype.

        // self.*.archetypes[self.entity_info[safe_entity].archetype_idx]. # TODO
        // self.entity_info[safe_entity] = EntityInfo{.archetype_idx = matching_arch, .packed_idx = to_archetype.components[component_name].len()};
    }

    pub fn get_component(self : *Self, entity : Entity,  component_name : []const u8, comptime component_type : type) !?component_type {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        const arche_info : EntityArche = self.*.entity_info.items[safe_entity].state;

        var ahhh_iter = self.*.archetypes.items[arche_info.Alive.archetype_idx].components.iterator();
        while(ahhh_iter.next()) |item| {
            std.debug.print("{}\n",.{item.key_ptr});
        }
        std.debug.print("uhhh\n",.{});

        var component_storage : *ComponentStorage(component_type) = self.*.archetypes.items[arche_info.Alive.archetype_idx].components.getPtr(component_name).?.*.cast(component_type);
        return component_storage.*.packed_set.get(safe_entity);
    } 
};

test "ECS declaration" {
    const meatbag = struct { health: u32, something_else: i64 };
    const vec2 = struct { x: f32, y: f32 };
    const transform = struct { position: vec2, rotation: f32, velocity: vec2 };

    var world = try ECS.init();
    defer world.deinit();

    const player_ent = try world.new_entity();
    try world.add_component(player_ent, "meatbag", meatbag{ .health = 2, .something_else = 123 });
    try world.add_component(player_ent, "transform", transform{ .position = .{ .x = 2, .y = 1 }, .rotation = 42.3, .velocity = .{ .x = 0, .y = 0 } });

    const enemy_ent = try world.new_entity();
    _ = enemy_ent;

    var player_comp: meatbag = (try world.get_component(player_ent, "meatbag", meatbag)).?;
    std.debug.print("{}\n", .{player_comp});
}

// test "Remove Component" {
//     const Name = struct { name: []u8 };

//     var world = ECS.init();
//     defer world.deinit();

//     const entity_1 = try world.new_entity();
//     try world.add_component(entity_1, "name", Name{ .name = @constCast("Jim") });
//     const entity_2 = try world.new_entity();
//     try world.add_component(entity_2, "name", Name{ .name = @constCast("Julia") });
//     const entity_3 = try world.new_entity();
//     try world.add_component(entity_3, "name", Name{ .name = @constCast("Alexa") });

//     try world.remove_component(entity_1, "name");
//     std.debug.assert((try world.get_component(entity_1, "name", Name)) == null);
//     std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_2, "name", Name)).?.name, @constCast("Julia")));
//     std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_3, "name", Name)).?.name, @constCast("Alexa")));
// }

// test "Writing Components" {
//     const Name = struct { name: []u8 };

//     var world = ECS.init();
//     defer world.deinit();

//     const clutter_ent_1 = try world.new_entity();
//     try world.add_component(clutter_ent_1, "name", Name{ .name = @constCast("Aleric") });

//     const entity_1 = try world.new_entity();
//     try world.add_component(entity_1, "name", Name{ .name = @constCast("Jessica") });
//     const clutter_ent_2 = try world.new_entity();
//     try world.add_component(clutter_ent_2, "name", Name{ .name = @constCast("Isabella") });

//     std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.name, @constCast("Jessica")));

//     try world.write_component(entity_1, "name", Name{ .name = @constCast("Rose") });

//     std.debug.assert(std.mem.eql(u8, (try world.get_component(entity_1, "name", Name)).?.name, @constCast("Rose")));
// }

// test "Slicing Component" {
//     const Meatbag = struct { health: u32, armor: u32 };
//     const Vec2 = struct { x: f32, y: f32 };
//     const Distance: *const fn (Vec2, Vec2) f32 = struct {
//         pub fn d(pnt1: Vec2, pnt2: Vec2) f32 {
//             return std.math.sqrt(std.math.pow(f32, pnt1.x - pnt2.x, 2) + std.math.pow(f32, pnt1.y - pnt2.y, 2));
//         }
//     }.d;
//     _ = Distance;
//     const Transform = struct { position: Vec2 };

//     var world = ECS.init();
//     defer world.deinit();

//     const entity_1 = try world.new_entity();
//     try world.add_component(entity_1, "meatbag", Meatbag{ .health = 42, .armor = 4 });
//     try world.add_component(entity_1, "transform", Transform{ .position = .{ .x = 1, .y = 1 } });
//     const entity_2 = try world.new_entity();
//     try world.add_component(entity_2, "meatbag", Meatbag{ .health = 99, .armor = 8 });
//     try world.add_component(entity_2, "transform", Transform{ .position = .{ .x = -1, .y = -1 } });

//     var meatbag_slice = world.get_slice_of("meatbag", Meatbag);
//     var transform_slice = world.get_slie_of("transform", Transform);
//     for (meatbag_slice.items(.health), meatbag_slice.items(.armor), transform_slice.items(.position)) |*health, armor, *position| {
//         _ = position;
//         _ = armor;
//         _ = health;
//     }
// }
