const std = @import("std");
const testing = std.testing;

// Is a unique id.
const Entity = ?usize;

const component_allocator = std.testing.allocator;

const ComponentStorageError = error{ EntityMissingComponent, InvalidEntity, OldEntity };

// TODO: Turn this struct into PackedSet
fn ComponentStorage(comptime ty: type) type {
    return struct {
        const Self = @This();

        // This array represents whether an entity has a component, and where to find it.
        // If an entry is 0, that entity doesn't have this component. Otherwise,
        // the entity's component's data is in the packed set at index i-1, where i is the
        // value in the sparse sent.
        sparse_set: std.ArrayList(?usize),
        packed_set: std.MultiArrayList(ty),

        pub fn init(self: *Self, alloc_count: usize) !void {
            self.sparse_set = std.ArrayList(?usize).init(component_allocator);
            self.packed_set = .{};
            try self.sparse_set.resize(alloc_count);

            // initalize all new component indicies to null.
            for (self.sparse_set.items) |*item| {
                item.* = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.*.sparse_set.deinit();
            self.*.packed_set.deinit(component_allocator);
        }

        // This will be called whenever space for a new entity should be made.
        pub fn add_one(self: *Self) !void {
            (try self.*.sparse_set.addOne()).* = null;
        }

        pub fn write_component(self: *Self, entity: Entity, data: ty) !void {
            const entity_safe = entity orelse return ComponentStorageError.InvalidEntity;

            // This means this entity doesn't have an Entity, error!
            const component_index: usize = self.*.sparse_set.items[entity_safe] orelse return ComponentStorageError.EntityMissingComponent;

            self.*.packed_set.set(component_index, data);
        }

        pub fn add_component(self: *Self, entity: Entity, data: ty) !void {
            const entity_safe = entity orelse return ComponentStorageError.InvalidEntity;

            const component_index: *?usize = &self.*.sparse_set.items[entity_safe];

            // We can use == null becaues component_index is optional.
            if (component_index.* == null) {
                // If this entity doesn't have a component, add one!
                try self.*.packed_set.append(component_allocator, data);
            }

            // Index into packed set that is where the new data lives.
            const new_data_index = self.*.packed_set.len - 1;

            self.*.sparse_set.items[entity_safe] = new_data_index;
        }

        pub fn remove_component(self: *Self, entity: Entity) !void {
            const entity_safe = entity orelse return ComponentStorageError.InvalidEntity;
            const component_index: *?usize = &self.*.sparse_set.items[entity_safe];

            if (component_index.* == null) return ComponentStorageError.InvalidEntity;

            // How this removal works, is that we move the last item in the packed set
            // to replace the place of this component, and update the sparse set indices.
            // Unless, of course, this component is the last, then it's easy.
            if (component_index.*.? == self.*.packed_set.len - 1) {
                component_index.*.? = 0;
                return self.*.packed_set.resize(component_allocator, self.*.packed_set.len - 1);
            }

            // Ok, so we need to swap this component and the last component.
            // Search for an index to the last component.
            const last_index_sparse_ptr: *usize = for (self.*.sparse_set.items) |*index| {
                if (index.* == self.*.packed_set.len - 1) {
                    break &(index.*.?); // If it is equal to a number, it can't be null.
                }
            } else {
                // This will happen whenever there is no sparse set entry that points to the
                // last item in the packed set; it should never happen.
                unreachable;
            };

            self.*.packed_set.swapRemove(component_index.*.?);
            last_index_sparse_ptr.* = component_index.*.?;
            component_index.* = null;
        }

        // Use this function as little as possible! It is way slower because we are using MultiArrayList.
        pub fn get_component(self: *Self, entity: Entity) !?ty {
            const entity_safe = entity orelse return ComponentStorageError.InvalidEntity;
            const component_index: usize = self.*.sparse_set.items[entity_safe] orelse return null; // <-- returns null if this entity doesn't have this component.

            return self.*.packed_set.get(component_index);
        }

        pub fn get_slice(self : *Self) std.MultiArrayList(ty).Slice {
            return self.packed_set.slice();
        }
    };
}

const ComponentStorageErased = struct {
    const Self = @This();

    ptr: *anyopaque,
    deinit: *const fn (*Self) void,
    add_one: *const fn (*Self) anyerror!void,
    remove_component: *const fn (*Self, Entity) anyerror!void,

    pub fn init(comptime hidden_type: type, alloc_count: usize) !Self {
        const new_data = try component_allocator.create(ComponentStorage(hidden_type));
        try new_data.init(alloc_count);
        return Self{ .ptr = new_data, .deinit = struct {
            pub fn deinit(self: *Self) void {
                var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                hidden.deinit();
                component_allocator.destroy(hidden);
            }
        }.deinit, .add_one = struct {
            pub fn add_one(self: *Self) !void {
                var hidden = self.cast(hidden_type);
                try hidden.add_one();
            }
        }.add_one, .remove_component = struct {
            pub fn remove_component(self: *Self, ent: Entity) !void {
                var hidden = self.cast(hidden_type);
                return hidden.remove_component(ent);
            }
        }.remove_component };
    }

    pub fn cast(self: *Self, comptime cast_to: type) *ComponentStorage(cast_to) {
        return @ptrCast(@alignCast(self.*.ptr));
    }
};


const ECS = struct {
    components: std.StringArrayHashMap(ComponentStorageErased),
    next_entity: usize = 0,

    const Self = @This();
    pub fn init() Self {
        return Self{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator) };
    }
    pub fn deinit(self: *Self) void {
        for (self.*.components.values()) |*value| {
            value.*.deinit(value);
        }
        self.*.components.deinit();
    }

    pub fn new_entity(self: *Self) !Entity {
        self.*.next_entity += 1;

        // Add a new component slot for every component type.
        for (self.*.components.values()) |*value| {
            try value.*.add_one(value);
        }

        return self.*.next_entity - 1;
    }

    pub fn add_component(self: *Self, entity: Entity, name: []const u8, comptime component: anytype) !void {
        // Potentially register this component.
        var query = try self.*.components.getOrPut(name); // TODO: try getOrPutValue
        if (!query.found_existing) {
            query.value_ptr.* = try ComponentStorageErased.init(@TypeOf(component), self.*.next_entity);
        }
        // We have a component storage now (maybe just registered it). Can use 'query.value_ptr.*' to use it.

        try query.value_ptr.cast(@TypeOf(component)).*.add_component(entity, component);
    }

    pub fn get_component(self: *Self, entity: Entity, name: []const u8, comptime component_type: type) !?component_type {
        var query = self.*.components.get(name);
        if (query) |*res| {
            // 'name' is a component type.
            return res.*.cast(component_type).*.get_component(entity);
        }
        // TODO: Better errors!
        unreachable;
    }

    pub fn remove_component(self: *Self, entity: Entity, name: []const u8) !void {
        var query = self.*.components.get(name);
        if (query) |*value| {
            return value.*.remove_component(value, entity);
        }
        // TODO: Better errors!
        unreachable;
    }

    pub fn write_component(self: *Self, entity: Entity, name: []const u8, comptime component: anytype) !void {
        var query = self.*.components.get(name);
        if (query) |*value| {
            return value.*.cast(@TypeOf(component)).*.write_component(entity, component);
        }
        unreachable;
    }

    pub fn get_slice_of(self: *Self, name: []const u8, comptime component_type : type) std.MultiArrayList(component_type).Slice {
        var query = self.*.components.get(name);
        if (query) |*value| {
            return value.*.cast(component_type).*.get_slice();
        }
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

    std.debug.assert(
        std.mem.eql(
            u8,
            (try world.get_component(entity_1, "name", Name)).?.name,
            @constCast("Jessica")
    ));

    try world.write_component(entity_1, "name", Name{.name = @constCast("Rose")});

    std.debug.assert(
        std.mem.eql(
            u8,
            (try world.get_component(entity_1, "name", Name)).?.name,
            @constCast("Rose")
    ));
}

test "Slicing Component" {
    const Meatbag = struct {health : u32, armor : u32 };
    const Vec2 = struct {x : f32, y: f32};
    const Distance : *const fn(Vec2,Vec2) f32 = struct { pub fn d(pnt1 : Vec2, pnt2 : Vec2) f32 {
        return std.math.sqrt( std.math.pow(f32, pnt1.x - pnt2.x, 2) + std.math.pow(f32, pnt1.y - pnt2.y, 2) );
    }}.d;
    _ = Distance;
    const Transform = struct {position : Vec2 };
    
    var world = ECS.init();
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "meatbag", Meatbag{.health = 42, .armor = 4});
    try world.add_component(entity_1, "transform", Transform{.position = .{.x=1,.y=1}} );
    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "meatbag", Meatbag{.health = 99, .armor = 8});
    try world.add_component(entity_2, "transform", Transform{.position = .{.x=-1,.y=-1}} );


    var meatbag_slice = world.get_slice_of("meatbag",Meatbag);
    var transform_slice = world.get_slie_of("transform", Transform);
    for(meatbag_slice.items(.health), meatbag_slice.items(.armor), transform_slice.items(.position)) |*health,armor,*position| {
        _ = position;
        _ = armor;
        _ = health;
        
    }

}