// There are some problems with this Entity Component System (ECS).
// The first thing to note is that archetypes are stored in an array that has holes.
// When you delete archetypes, there is no reordering, but when you make new archetypes the ECS
// will try to fill those holes. So, there can be wasted space when you go to every entity having
// a unique set of components to every entity having the same components, the same components as the
// last created unique entity thing. This isn't terrible though.

const std = @import("std");
const testing = std.testing;

pub const std_options = struct {
    pub const log_level = .debug;
};

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
    get_field_ptr: *const fn (*Self, []const u8) anyerror!*anyopaque,

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
            .get_field_ptr = struct {
                pub fn get_field_ptr(self: *Self, name: []const u8) anyerror!*anyopaque {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    const component_member_field = @field(std.MultiArrayList(hidden_type).Field, name);
                    return hidden.*.packed_set.items(component_member_field).ptr;
                }
            }.get_field_ptr,
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
    len: usize, // TODO: Test this

    pub fn init(components: [][]const u8, component_storages: []ComponentStorageErased) !Self {
        std.debug.assert(components.len == component_storages.len);
        var self: Self = .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .len = component_storages.len };
        for (components, component_storages) |component_name, component_storage| {
            try self.components.put(component_name, component_storage);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        var map_iter = self.*.components.iterator();
        while (map_iter.next()) |item| {
            var storage: *ComponentStorageErased = item.value_ptr;
            storage.*.deinit(storage);
        }
        self.*.components.deinit();
    }

    // This function will create a new 'Empty Archetype'
    pub fn init_empty() Self {
        return .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .len = 0 };
    }

    pub fn compare(self: *Self, compare_keys: [][]const u8) bool {
        for (self.*.components.keys()) |keys| {
            const was_found: bool = for (compare_keys) |compare_key| {
                if (std.mem.eql(u8, compare_key, keys) == true) {
                    break true;
                }
            } else inner: {
                break :inner false;
            };

            if (was_found == false) {
                return false;
            }
        }
        return true;
    }

    // Finds if this archetype contains *at least* these keys.
    pub fn contains(self: *Self, has_keys: [][]const u8) bool {
        for (has_keys) |could_key| {

            // This for loop returns whether 'could_key' was in the
            for (self.*.components.keys()) |key| {
                if (std.mem.eql(u8, could_key, key) == true) {
                    break;
                }
            } else {
                return false;
            }
        }
        return true;
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

const ECSError = error{ EntityMissingComponent, InvalidEntity, OldEntity, DeadEntity, EntityDoesNotHaveComponent };
const ECS = struct {
    entity_info: std.ArrayList(EntityInfo),

    // Archetypes will be created and destroyed, however entities reference archetypes by index.
    // So, they either need a layer of indirection (bad) or a clever non-congiuous thing (hard).
    // We'll do the non-congiuous thing.
    archetypes: std.ArrayList(?Archetype),
    archetype_count: usize,
    next_entity: usize = 0,

    const Self = @This();
    pub fn init() !Self {
        var archetypes = std.ArrayList(?Archetype).init(component_allocator);
        try archetypes.append(Archetype.init_empty());
        return Self{
            .entity_info = std.ArrayList(EntityInfo).init(component_allocator),
            .archetypes = archetypes,
            .archetype_count = 1,
            .next_entity = 0,
        };
    }
    pub fn deinit(self: *Self) void {
        for (self.*.archetypes.items) |*archetype| {
            archetype.*.?.deinit();
        }
        self.*.archetypes.deinit();
        self.*.entity_info.deinit();
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

        if (self.*.archetypes.items[self.*.entity_info.items[safe_entity.entity_id].state.Alive.archetype_idx] == null) {
            unreachable; // This isn't a user error, so perhaps this shouldn't be an error.
            // But, it might be important to tell zig that this code path shouldn't happen.
        }
    }

    pub inline fn unwrap_entity(self: *Self, entity: Entity) !usize {
        try self.*.check_entity(entity);
        return entity.?.entity_id;
    }

    // Move an entity from one archetype to another. Obviously, this can be dangerous.
    // You can use this function to go to a bigger or smaller archetype. If it is bigger, you are responsible for adding the new component.
    // If the source archetype has no components, then nothing will be written to the destination archetype,
    //  and you may need to update the packed set index if you add something again.
    fn move_entity(self: *Self, entity: Entity, from_index: usize, to_index: usize) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);

        // Incompletely remove component from entity.
        // This will only remove the component
        var from: *Archetype = &self.*.archetypes.items[from_index].?;
        var to: *Archetype = &self.*.archetypes.items[to_index].?;

        // Assert that the two archetypes should be only one component away from each other.
        std.debug.assert(try std.math.absInt(@as(i64, @intCast(from.*.len)) - @as(i64, @intCast(to.*.len))) == 1);
        // TODO: Assert that all but one component must match.

        // Go through all components from the 'from' archetype and move it to the 'to' archetype.
        var map_iter = from.*.components.iterator();
        var last_component_storage: ?std.StringArrayHashMap(ComponentStorageErased).Entry = null;
        while (map_iter.next()) |item| {
            const key = item.key_ptr.*;
            const value: *ComponentStorageErased = item.value_ptr;
            var to_component_storage: *ComponentStorageErased = to.*.components.getPtr(key) orelse continue;
            last_component_storage = item;

            // This way we know where the last item of the 'from' archetype went.
            const entity_index: usize = self.*.entity_info.items[safe_entity].state.Alive.packed_idx.?;

            try to_component_storage.*.take_from(to_component_storage, value, entity_index);
        }
        // All of the following steps could be in the above while loop, except that it would do the same thing many times.
        // Instead, we'll find what it needs to do and do it once.

        // We know that all of this data will be put at the end of to_component_storage.
        // Now update the sparse set and stuff!
        std.debug.print("Before archetype : {} | after archetype : {}\n", .{ self.*.entity_info.items[safe_entity].state.Alive.archetype_idx, to_index });
        self.*.entity_info.items[safe_entity].state.Alive.archetype_idx = to_index;

        // If the 'from' archetype has any components (and the 'to' archetype isn't 'Empty Archetype'), then
        if (last_component_storage) |item| {
            std.debug.print("There was some components\n", .{});
            const key = item.key_ptr.*;
            // We can assume now that we will never come across the 'Emtpy Archetype' here.
            var to_component_storage: *ComponentStorageErased = to.*.components.getPtr(key).?;
            const entity_index: usize = self.*.entity_info.items[safe_entity].state.Alive.packed_idx.?;

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
                // This will happen when there are no other entities left in this archetype.
                //unreachable;
            }
        }
    }

    pub fn add_component(self: *Self, entity: Entity, component_name: []const u8, comp_t: anytype) !void {
        // Unwrap entity.
        const safe_entity: usize = try self.*.unwrap_entity(entity);

        // Query the sparse set to see what archetype this entity is in (and its index).
        const ent_info: EntityInfo = self.*.entity_info.items[safe_entity];
        const arch: *Archetype = &self.*.archetypes.items[ent_info.state.Alive.archetype_idx].?;

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
        var matching_arch: ?usize = outer: for (0.., self.*.archetypes.items) |arch_idx, *archetype_opt| {
            var archetype: *Archetype = &archetype_opt.*.?;

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
            const arch_component_types: []ComponentStorageErased = try component_allocator.alloc(ComponentStorageErased, arch_component_names.len + 1); //[arch_component_names.len + 1]ComponentStorageErased{};
            defer component_allocator.free(arch_component_types);
            // write to the new ComponentStorages
            for (old_arch_component_types, arch_component_types[0 .. arch_component_types.len - 1]) |*component_storage, *new_component_storage| {
                new_component_storage.* = try component_storage.*.make_new(component_storage);
            }
            arch_component_types[arch_component_names.len] = try ComponentStorageErased.init(@TypeOf(comp_t)); // , self.*.next_entity

            var new_components = try component_allocator.alloc([]const u8, arch_component_names.len + 1); //[][arch_component_names.len + 1]u8{0};
            defer component_allocator.free(new_components);

            std.mem.copyForwards([]const u8, new_components[0..new_components.len], arch_component_names);
            new_components[arch_component_names.len] = component_name;

            try self.archetypes.append(try Archetype.init(new_components, arch_component_types));
            matching_arch = self.archetypes.items.len - 1;
        }
        std.debug.assert(matching_arch != null);

        const to_archetype: *Archetype = &self.*.archetypes.items[matching_arch.?].?;

        try self.move_entity(entity, ent_info.state.Alive.archetype_idx, matching_arch.?);

        // Finally, add the new component.
        var new_component_storage_erased: *ComponentStorageErased = to_archetype.*.components.getPtr(component_name).?;
        var new_component_storage: *ComponentStorage(@TypeOf(comp_t)) = new_component_storage_erased.*.cast(@TypeOf(comp_t));
        try new_component_storage.*.packed_set.append(component_allocator, comp_t);

        // Is the to_archetype the "Empty Archetype"?
        if (ent_info.state.Alive.archetype_idx == 0) {
            // If it is, update the packed set index to reflect it.
            self.*.entity_info.items[safe_entity].state.Alive.packed_idx = new_component_storage.*.packed_set.len - 1;
        }
    }

    pub fn get_component(self: *Self, entity: Entity, component_name: []const u8, comptime component_type: type) !?component_type {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        const arche_info: EntityArche = self.*.entity_info.items[safe_entity].state;
        std.debug.print("\nentity : {}\nversion : {}\narchetype index : {}\n", .{ safe_entity, entity.?.version, arche_info.Alive.archetype_idx });
        std.debug.print("Archetype count : {}\n", .{self.*.archetypes.items.len});

        var ahhh_iter = self.*.archetypes.items[arche_info.Alive.archetype_idx].?.components.iterator();
        while (ahhh_iter.next()) |item| {
            std.debug.print("{}\n", .{item.key_ptr});
        }

        if (self.*.archetypes.items[arche_info.Alive.archetype_idx].?.components.getPtr(component_name)) |component_storage_unwrap| {
            var component_storage: *ComponentStorage(component_type) = component_storage_unwrap.*.cast(component_type);
            return component_storage.*.packed_set.get(safe_entity);
        } else {
            return null;
        }
    }

    pub fn remove_component(self: *Self, entity: Entity, component_name: []const u8) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        var entity_info: *EntityInfo = &self.*.entity_info.items[safe_entity];

        var current_archetype_idx = entity_info.*.state.Alive.archetype_idx;
        var current_archetype: *Archetype = &self.*.archetypes.items[current_archetype_idx].?;

        if (current_archetype.*.components.get(component_name) == null) {
            return ECSError.EntityDoesNotHaveComponent;
        }

        if (current_archetype.*.len == 1) {
            // Simply move this entity to the 'Empty Architecture'
            try self.*.move_entity(entity, current_archetype_idx, 0);
            // I don't think there is any cleanup.
            entity_info.*.state.Alive.archetype_idx = 0;
            entity_info.*.state.Alive.packed_idx = null;
        } else {
            // Make a new array of component names that will contain all of the names of the components
            // this entity has *except* for 'component_name', as we are deleting that one.
            var component_query: [][]const u8 = try component_allocator.alloc([]const u8, current_archetype.*.len - 1);
            defer component_allocator.free(component_query);

            const current_components: [][]const u8 = current_archetype.*.components.keys();
            //Find where the component to be removed is in the current_components.
            const removing_component: usize = for (0.., current_components) |index, component| {
                //if (std.mem.orderZ(u8, component, component_name) == std.math.Order.eq) {
                if (std.mem.eql(u8, component, component_name)) {
                    break index;
                }
            } else {
                unreachable;
            };

            @memcpy(component_query, current_components[0..removing_component]);
            if (removing_component != current_archetype.len) { // I dunno what would happen if I didn't have this...
                @memcpy(component_query[removing_component..], current_components[removing_component + 1 ..]);
            }

            // find an archetype that matches the 'component_query'. Then
            for (0.., self.*.archetypes.items) |index, *item| {
                var archetype: *Archetype = &item.*.?;
                if (archetype.*.compare(component_query) == true) {
                    // This archetype is the guy.
                    try self.*.move_entity(entity, current_archetype_idx, index);
                    break;
                }
            } else {
                // There is no archetype that has this set of components, create a new one.
                var component_storage: []ComponentStorageErased = try component_allocator.alloc(ComponentStorageErased, component_query.len);

                // Use the component storages from the 'from' archetype to create the component storages we need for the 'to' archetype.
                for (component_query, component_storage) |component, *item| {
                    var component_storage_er: *ComponentStorageErased = current_archetype.*.components.getPtr(component).?;
                    item.* = try component_storage_er.*.make_new(component_storage_er);
                }

                // TODO: make this fill holes rather than just append.
                try self.*.archetypes.append(try Archetype.init(component_query, component_storage));
                self.*.archetype_count += 1;

                // Move entity.
                try self.*.move_entity(entity, current_archetype_idx, self.*.archetype_count - 1);
            }
        }

        // And, if the old archetype is now empty, kill it!
        //if (current_archetype.*.components) {
        //    self.*.archetypes.items[current_archetype_idx] = null;
        //}
    }

    pub fn write_component(self: *Self, entity: Entity, component_name: []const u8, data: anytype) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        var entity_info: *EntityInfo = &self.*.entity_info.items[safe_entity];
        var archetype: *Archetype = &(self.*.archetypes.items[entity_info.*.state.Alive.archetype_idx] orelse unreachable);
        var component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(component_name) orelse return ECSError.EntityDoesNotHaveComponent;
        var component_storage: *ComponentStorage(@TypeOf(data)) = component_storage_erased.*.cast(@TypeOf(data));
        component_storage.*.packed_set.set(entity_info.state.Alive.packed_idx.?, data);
    }
};

pub fn data_iter(comptime components: anytype) type {
    const desc_type = @TypeOf(components); // Type of the input object.
    const DescField = std.meta.FieldEnum(desc_type);
    _ = DescField; // Enum type where each key is the field name.
    const desc_type_info: std.builtin.Type = @typeInfo(desc_type); // Type information on the input type.
    const struct_decl: std.builtin.Type.Struct = desc_type_info.Struct;

    // These are the component names and component types the user has provided.
    var field_names: [desc_type_info.Struct.fields.len][]const u8 = undefined;
    comptime var field_types: [desc_type_info.Struct.fields.len]type = undefined;

    // the number of fields in each component.
    var barray_map: [desc_type_info.Struct.fields.len]usize = undefined;
    // ====================

    // Go populate the above things.
    inline for (0.., desc_type_info.Struct.fields) |index, field| {
        field_names[index] = field.name;
        const field_type: type = @field(components, field.name);
        field_types[index] = field_type;
        barray_map[index] = @typeInfo(field_type).Struct.fields.len; // Get the number of fields in this component.
    }

    // searches field_names and field_types for an input string, and returns the coorisponding type from field_types.
    const find_type = struct {
        pub fn find_type(comptime field_names_inner: [][]const u8, comptime field_types_inner: []type, comptime type_name: []const u8) type {
            for (field_names_inner, field_types_inner) |name, type_t| {
                if (std.mem.eql(u8, name, type_name) == true) {
                    return type_t;
                }
            }
            unreachable;
        }
    }.find_type;

    // This function takes a struct and returns a new struct where all of the members are pointer-ized.
    const pointer_type = struct {
        pub fn pointer_type(comptime in_struct: type) type {
            const struct_info: std.builtin.Type.Struct = @typeInfo(in_struct).Struct;
            var new_fields: [struct_info.fields.len]std.builtin.Type.StructField = undefined;
            for (struct_info.fields, &new_fields) |field, *new_field| {
                new_field.*.alignment = 0;
                new_field.*.default_value = null;
                new_field.*.is_comptime = false;
                new_field.*.name = "PtrOf" ++ field.name;
                new_field.*.type = @Type(.{
                    .Pointer = .{
                        .size = std.builtin.Type.Pointer.Size.One,
                        .is_const = false,
                        .is_volatile = false,
                        .alignment = 8,
                        .address_space = std.builtin.AddressSpace.generic,
                        .child = field.type, // This is very important!
                        .is_allowzero = false,
                        .sentinel = null,
                    },
                });
            }

            return @Type(.{ .Struct = .{ .layout = std.builtin.Type.ContainerLayout.Auto, .fields = new_fields[0..], .decls = &[_]std.builtin.Type.Declaration{}, .is_tuple = false } });
        }
    }.pointer_type;

    // This type describes one iteration of the slicing process.
    // Each field is one of the component names, like .meatbag, .transform, or such.
    // Within each of those is all of the fields of the component, except a pointer to it.
    var fields: [struct_decl.fields.len]std.builtin.Type.StructField = undefined;
    for (&fields, field_names, field_types) |*field, field_name, field_type| {
        field.*.name = field_name;
        field.*.type = pointer_type(field_type);
        field.*.alignment = 0;
        field.*.is_comptime = false;
        field.*.default_value = null;
    }
    const slice_type = @Type(.{ .Struct = .{ .layout = .Auto, .fields = fields[0..], .decls = &[_]std.builtin.Type.Declaration{}, .is_tuple = false } });

    const slice_type_info: std.builtin.Type.Struct = @typeInfo(slice_type).Struct;

    const baked_names: [desc_type_info.Struct.fields.len][]const u8 = field_names;

    return struct {
        archetype_idx: ?usize,
        packed_idx: ?usize,
        ecs: *ECS,
        slice: slice_type,
        // an array of member offsets from slice's start.
        pub fn init(ecs: *ECS) @This() {
            const first_archetype: ?usize = for (0.., ecs.*.archetypes.items) |index, *archetype_maybe| {
                var archetype: *Archetype = &(archetype_maybe.* orelse continue);
                if (archetype.*.contains(@constCast(baked_names[0..]))) {
                    break index;
                }
            } else inner: {
                break :inner null;
            };

            return .{ .archetype_idx = first_archetype, .packed_idx = null, .ecs = ecs, .slice = undefined };
        }

        pub fn next(self: *@This()) ?slice_type {
            if (self.*.archetype_idx == null) return null;
            const safe_archetype_idx: usize = self.*.archetype_idx.?;
            var archetype: *Archetype = &self.*.ecs.*.archetypes.items[safe_archetype_idx].?;

            if (self.*.packed_idx == null) {
                //TODO: if this archetype does not have any component (assert, this shouldn't happen) then iterate to the next archetype.

                // This huge for loop will get the sum of the component's fields.
                comptime var member_counter: usize = 0;
                inline for (slice_type_info.fields) |field| {
                    //fields.name
                    const component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(field.name).?;
                    const field_type: type = find_type(@constCast(baked_names[0..]), @constCast(field_types[0..]), field.name);
                    var component_storage: *ComponentStorage(field_type) = component_storage_erased.cast(field_type);
                    std.debug.assert(component_storage.*.packed_set.len > 0);
                    // Iterate through all the fields of this component.
                    const component_type_info: std.builtin.Type.Struct = @typeInfo(field_type).Struct;
                    var slice_for_component: *pointer_type(field_type) = &@field(self.*.slice, field.name);
                    _ = slice_for_component;
                    inline for (component_type_info.fields) |component_field| {
                        _ = component_field;
                        member_counter += 1;
                        // const pointer_thing: []*field_type = component_storage.*.packed_set.items(@field(component_storage.*.packed_set.Field, component_field.name));
                        // slice_for_component.* = pointer_thing.ptr;
                    }
                }

                // This for loop will populate these arrays with the information.
                var wuh_component_storage: [member_counter]*ComponentStorageErased = undefined;
                // comptime var wuh_types: [member_counter]type = undefined;
                comptime var wuh_names: [member_counter][]const u8 = undefined;
                comptime var counter: usize = 0;
                inline for (slice_type_info.fields) |field| {
                    //fields.name
                    const component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(field.name).?;
                    const field_type: type = find_type(@constCast(baked_names[0..]), @constCast(field_types[0..]), field.name);
                    var component_storage: *ComponentStorage(field_type) = component_storage_erased.cast(field_type);
                    std.debug.assert(component_storage.*.packed_set.len > 0);
                    // Iterate through all the fields of this component.
                    const component_type_info: std.builtin.Type.Struct = @typeInfo(field_type).Struct;
                    var slice_for_component: *pointer_type(field_type) = &@field(self.*.slice, field.name);
                    _ = slice_for_component;
                    inline for (component_type_info.fields) |component_field| {
                        wuh_component_storage[counter] = component_storage_erased;
                        // wuh_types[counter] = field_type;
                        wuh_names[counter] = component_field.name;
                        counter += 1;
                        // const pointer_thing: []*field_type = component_storage.*.packed_set.items(@field(component_storage.*.packed_set.Field, component_field.name));
                        // slice_for_component.* = pointer_thing.ptr;
                    }
                }

                comptime var i: usize = 0;
                inline while (i < member_counter) {
                    // const ahhh: *const fn (*ComponentStorageErased, []const u8) anyerror!*anyopaque = wuh_component_storage[i].get_field_ptr;
                    // var component_storage: *ComponentStorage(wuh_types[i]) = wuh_component_storage[i].cast(wuh_types[i]);
                    // _ = component_storage;

                    i += 1;
                }
                // for (wuh_component_storage, wuh_types, wuh_names) |component_storage_erased, comp_t, name| {
                //     _ = name;
                //     _ = comp_t;
                //     _ = component_storage_erased;
                // }

                // go through all the members of 'slice', and all of those members, and set it to the thing.
            }

            return null;
        }
    };
}

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

test "Remove Component" {
    const Name = struct { name: []u8 };

    var world = try ECS.init();
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

    var world = try ECS.init();
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

    var world = try ECS.init();
    defer world.deinit();

    const entity_1 = try world.new_entity();
    try world.add_component(entity_1, "meatbag", Meatbag{ .health = 42, .armor = 4 });
    try world.add_component(entity_1, "transform", Transform{ .position = .{ .x = 1, .y = 1 } });
    const entity_2 = try world.new_entity();
    try world.add_component(entity_2, "meatbag", Meatbag{ .health = 99, .armor = 8 });
    try world.add_component(entity_2, "transform", Transform{ .position = .{ .x = -1, .y = -1 } });

    //var iter = DataIter()
    //    .over(.meatbag, Meatbag, .{.health})
    //    .over(.transform, Transform, .{.position})
    //    .init(&world);
    var iter = data_iter(.{ .meatbag = Meatbag, .transform = Transform }).init(&world);

    var slice = iter.next();
    _ = slice;
    //std.debug.print("{s}", .{std.fmt.comptimePrint("{s}\n", @typeName(@TypeOf(slice)))});
    // std.debug.print("{s}\n", .{std.fmt.comptimePrint("{}", .{@typeInfo(@typeInfo(@TypeOf(slice)).Optional.child)})});
    // inline for (@typeInfo(@typeInfo(@TypeOf(slice)).Optional.child).Struct.fields) |field| {
    //     std.debug.print("{s}\n", .{std.fmt.comptimePrint("{}", .{field})});
    // }

    //while (iter.next()) |slice| {
    //    std.debug.print("{s}", .{std.fmt.comptimePrint("{s}\n", @typeName(@TypeOf(slice)))});
    //    //std.debug.print("{}", .{std.fmt.comptimePrint("{}\n", @typeInfo(@TypeOf(slice)))});
    //    //const health: *u32 = slice.meatbag.health;
    //}
}
