// Author : David Medin
// Email : david@davidmedin.com
// Zig Version : 0.12.0-dev.21+ac95cfe44

// TODO:
// [x] Functions for returning information on the system
//    [x] Return Number of Archetypes & what components are in each archetype and the number of entities in an archetype
// [x] Iteration includes .entity
// [] make data_iter work for every entity ( .{} should result in iterating through all entities)
// [] Batch add and remove components
// [] check_health function. Sanity checks everything I can think of. ie all ComponentManagerErased's should have the same length in one archetype.

const std = @import("std");
const testing = std.testing;
// This is how you can use std.log.* using the Playdate's logToConsole function. If want to use std.debug.print, cry, seeth, cope, commit nix
// pub const std_options = struct {
//     pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
//         _ = scope;
//         const ED = comptime "\x1b[";
//         _ = ED;
//         const reset = "\x1b[0m";
//         _ = reset;

//         const prefix = "[" ++ comptime level.asText() ++ "] ";
//         nosuspend std.debug.print(prefix ++ format ++ "", args);
//     }
// };

// Is a unique id.
const RawEntity = struct { entity_id: usize, version: usize };
pub const Entity = ?RawEntity;

// TODO: Store the entity information right next to the component.
fn ComponentStorage(comptime ty: type) type {
    return struct {
        const Self = @This();

        packed_set: std.ArrayList(ty),

        pub fn init(self: *Self, component_allocator: std.mem.Allocator) !void {
            self.packed_set = std.ArrayList(ty).init(component_allocator);
        }

        pub fn deinit(self: *Self) void {
            self.*.packed_set.deinit();
        }
    };
}

const ComponentStorageErased = struct {
    const Self = @This();

    ptr: *anyopaque,
    component_allocator: std.mem.Allocator,
    deinit: *const fn (*Self) void,
    len: *const fn (*Self) usize,
    make_new: *const fn (*Self) anyerror!Self,
    swap_del: *const fn (*Self, usize) anyerror!void,
    take_from: *const fn (*Self, *ComponentStorageErased, usize) anyerror!void,

    pub fn init(comptime hidden_type: type, component_allocator: std.mem.Allocator) !Self {
        const new_data = try component_allocator.create(ComponentStorage(hidden_type));
        try new_data.init(component_allocator);

        return Self{
            .component_allocator = component_allocator,
            .ptr = new_data,
            .deinit = struct {
                pub fn deinit(self: *Self) void {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    hidden.deinit();
                    self.*.component_allocator.destroy(hidden);
                }
            }.deinit,
            .make_new = struct {
                pub fn make_new(self: *Self) !Self {
                    return Self.init(hidden_type, self.*.component_allocator);
                }
            }.make_new,

            .len = struct {
                pub fn len(self: *Self) usize {
                    var hidden: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    return hidden.*.packed_set.items.len;
                }
            }.len,
            .swap_del = struct {
                pub fn swap_del(self : *Self, index : usize) anyerror!void {
                    var hidden_self: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    _ = hidden_self.*.packed_set.swapRemove(index);
                }
            }.swap_del,
            .take_from = struct {
                // This function will take the component from 'take_from_this' at index 'from_index' and move it to
                // self's end. Note, this does not know what an 'ECS' is, and will not adjust the Grand Sparse Set.
                pub fn take_from(self: *Self, take_from_this: *ComponentStorageErased, from_index: usize) anyerror!void {
                    var hidden_self: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(self.*.ptr));
                    var hidden_from: *ComponentStorage(hidden_type) = @ptrCast(@alignCast(take_from_this.*.ptr));

                    // copy the value
                    // const moving_value: hidden_type = hidden_from.*.packed_set.items[from_index];
                    //Remove the value
                    const moving_value : hidden_type = hidden_from.*.packed_set.swapRemove(from_index);
                    //write the value to the other component storage.
                    try hidden_self.*.packed_set.append(moving_value);
                }
            }.take_from,
        };
    }

    // Cast this type erased component storage to a typed one.
    pub fn cast(self: *Self, comptime cast_to: type) *ComponentStorage(cast_to) {
        return @ptrCast(@alignCast(self.*.ptr));
    }

    // Get the pointer to the internal array.
    pub fn get_field_ptr(comptime cast_to: type) *const fn (*ComponentStorageErased) *anyopaque {
        return struct {
            pub fn ahhh(self: *Self) *anyopaque {
                const hidden: *ComponentStorage(cast_to) = @ptrCast(@alignCast(self.*.ptr));
                return hidden.*.packed_set.items.ptr;
            }
        }.ahhh;
    }

    // Index the internal array.
    pub fn anon_index(comptime cast_to: type) *const fn (*ComponentStorageErased, usize) *anyopaque {
        return struct {
            pub fn ahhh(self: *Self, index: usize) *anyopaque {
                const hidden: *ComponentStorage(cast_to) = @ptrCast(@alignCast(self.*.ptr));

                // I wonder if this is easier to do with a std library thing :hrmm:
                std.debug.assert(index >= 0);
                std.debug.assert(index < hidden.*.packed_set.items.len);
                return @ptrCast(&hidden.*.packed_set.items[index]);
            }
        }.ahhh;
    }
};

// An archetype is a collection of Component Storages. Each archetype store the components of entities
// that all have exactly the same components.
// There is also an 'Emtpy Archetype', which all entities that have no components are in. This archetype will always
// exist. In the ECS, it will always be the first archetype.
const Archetype = struct {
    const Self = @This();
    components: std.StringArrayHashMap(ComponentStorageErased),
    entity_count: usize,

    pub fn init(component_allocator: std.mem.Allocator, components: [][]const u8, component_storages: []ComponentStorageErased) !Self {
        std.debug.assert(components.len == component_storages.len);
        var self: Self = .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .entity_count = 0 };
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
    pub fn init_empty(component_allocator: std.mem.Allocator) Self {
        return .{ .components = std.StringArrayHashMap(ComponentStorageErased).init(component_allocator), .entity_count = 0 };
    }

    // Returns true if compare_keys - which is an slice of strings - is exactly the component names of the Archetype.
    pub fn compare(self: *Self, compare_keys: [][]const u8) bool {
        if(self.*.components.count() != compare_keys.len) {
            return false; // We just know that it is false.
        }
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

pub const ECSError = error{ EntityMissingComponent, InvalidEntity, OldEntity, EntityDoesNotHaveComponent }; // Removed : DeadEntity
pub const ECSConfig = struct { component_allocator: std.mem.Allocator };
pub const ECS = struct {
    const EntCompPair = struct {entity : RawEntity, component : []u8};

    ecs_config: ECSConfig,
    entity_info: std.ArrayList(EntityInfo),

    // Archetypes will be created and destroyed, however entities reference archetypes by index.
    // So, they either need a layer of indirection (bad) or a clever non-congiuous thing (hard).
    // We'll do the non-congiuous thing.
    archetypes: std.ArrayList(?Archetype),
    archetype_count: usize,

    remove_queue : std.ArrayList(EntCompPair),
    kill_queue : std.ArrayList(RawEntity),
    next_entity: usize = 0,

    const Self = @This();
    pub fn init(ecs_config: ECSConfig) !Self {
        var archetypes = std.ArrayList(?Archetype).init(ecs_config.component_allocator);
        try archetypes.append(Archetype.init_empty(ecs_config.component_allocator));
        return Self{ 
            .remove_queue = std.ArrayList(EntCompPair).init(ecs_config.component_allocator),
            .kill_queue = std.ArrayList(RawEntity).init(ecs_config.component_allocator),
            .entity_info = std.ArrayList(EntityInfo).init(ecs_config.component_allocator),
            .archetypes = archetypes,
            .archetype_count = 1,
            .next_entity = 0,
            .ecs_config = ecs_config
        };
    }
    pub fn deinit(self: *Self) void {
        for (self.*.archetypes.items) |*maybe_archetype| {
            if (maybe_archetype.*) |*archetype| {
                archetype.*.deinit();
            }
        }
        self.*.archetypes.deinit();
        self.*.entity_info.deinit();
        self.*.kill_queue.deinit();
        self.*.remove_queue.deinit();
    }

    pub fn queue_kill_entity(self : *Self, entity : Entity) !void {
        try self.check_entity(entity);
        self.*.kill_queue.AddOne(entity.?);
    }

    pub fn queue_remove_component(self : *Self, entity : Entity, component : []u8) !void {
        try self.check_entity(entity);
        self.*.remove_queue.addOne(.{.entity = entity.?, .component = component});
    }

    pub fn remove_queued_components(self : *Self) !void {
        for(self.*.remove_queue.items) |item| {
            try self.remove_component(item.entity, item.component);
        }
        self.*.remove_queue.clearAndFree();
    }

    pub fn kill_queued_entities(self : *Self) !void {
        for(self.*.kill_queue.items) |entity| {
            try self.*.kill_entity(entity);
        }
        self.*.kill_queue.clearAndFree();
    }

    // If all you know is where a component is, this will get you the entity. Warning!: Slow! TODO: store the entity right next to the component maybe.
    fn find_entity(self: *Self, archetype_idx: usize, packed_idx: ?usize) Entity {
        for (0.., self.*.entity_info.items) |index, entity_info| {
            // Switch to unwrap .Alive.
            switch (entity_info.state) {
                .Alive => |alive| {
                    if (alive.archetype_idx == archetype_idx and alive.packed_idx == packed_idx) {
                        return RawEntity{ .entity_id = index, .version = entity_info.version };
                    }
                },
                .Dead => {},
            }
        }
        return null;
    }

    pub fn print_info(self: *Self) void {
        // Print the number of Entities.
        // Print the number of 'used' components (maybe)
        // Print the number of Archetypes.
        // Iterate through Archetypes & print the components they hold and the number of entites per archetype.
        const print = std.log.debug;
        print("Entity count : {}", .{self.*.next_entity});
        print("Archetype count : {}", .{self.*.archetypes.items.len});
        for (0.., self.*.archetypes.items) |index, *maybe_archetype| {
            if (maybe_archetype.*) |*archetype| {
                print("\tArchetype : {} - Entity count : {}", .{ index, archetype.*.entity_count });
                const components: *std.StringArrayHashMap(ComponentStorageErased) = &archetype.*.components;
                var component_iter = components.*.iterator();
                while (component_iter.next()) |entry| {
                    print("\t\tComponent : {s}", .{entry.key_ptr.*});
                }
            } else {
                print("\tArchetype : {} - Empty", .{index});
            }
        }
    }

    pub fn new_entity(self: *Self) !Entity {
        // Try to find an entity that is dead.
        var entity_id : usize = undefined;
        var new_info: *EntityInfo = for(0..,self.*.entity_info.items) |index, *entity_info| {
            if(entity_info.*.state == .Dead) {
                entity_id = index;
                break entity_info;
            }
        }else thing: {
            entity_id = self.*.next_entity;
            self.*.next_entity += 1;
            const new_info = try self.*.entity_info.addOne();
            new_info.*.version = 0;
            break :thing new_info;
        };

        new_info.*.state = .{ .Alive = .{ .archetype_idx = 0, .packed_idx = null } };
        self.*.archetypes.items[0].?.entity_count += 1;
        return .{ .entity_id = entity_id, .version = new_info.*.version };
    }

    // This function will return the RawEntity an Entity is hiding.
    // This function will error if the entity is invalid in any way.
    pub inline fn check_entity(self: *Self, entity: Entity) ECSError!void {
        const safe_entity: RawEntity = entity orelse return ECSError.InvalidEntity;
        if (safe_entity.version != self.*.entity_info.items[safe_entity.entity_id].version) {
            return ECSError.OldEntity;
        }
        if (self.*.entity_info.items[safe_entity.entity_id].state == EntityArche.Dead) {
            // return ECSError.DeadEntity;
            unreachable; // This shouldn't ever happen if the version are mismatched, unless the user constructed their own entity. Citation needed.
        }

        if (self.*.archetypes.items[self.*.entity_info.items[safe_entity.entity_id].state.Alive.archetype_idx] == null) {
            unreachable; // TODO: This isn't a user error, so perhaps this shouldn't be an error.
            // But, it might be important to tell zig that this code path shouldn't happen.
        }
    }

    pub inline fn unwrap_entity(self: *Self, entity: Entity) !usize {
        try self.*.check_entity(entity);
        return entity.?.entity_id;
    }

    // Like move_entity, but asserts that there is only one component difference between the two archetypes.
    fn move_entity_one(self: *Self, entity : Entity, from_index : usize, to_index : usize) !void {
        var from: *?Archetype = &self.*.archetypes.items[from_index];
        var to: *Archetype = &self.*.archetypes.items[to_index].?;
        const from_component_count: i64 = @intCast(from.*.?.components.count());
        const to_component_count: i64 = @intCast(to.*.components.count());
        std.debug.assert(try std.math.absInt(from_component_count - to_component_count) == 1);
        return self.move_entity(entity, from_index, to_index);
    }
    // Move an entity from one archetype to another. Obviously, this can be dangerous.
    // You can use this function to go to a bigger or smaller archetype. If it is bigger, you are responsible for adding the new components.
    // If the source archetype has no components, then nothing will be written to the destination archetype,
    //  and you may need to update the packed set index if you add something again.
    fn move_entity(self: *Self, entity: Entity, from_index: usize, to_index: usize) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);

        // Incompletely remove component from entity.
        // This will only remove the component
        var from: *?Archetype = &self.*.archetypes.items[from_index];
        var to: *Archetype = &self.*.archetypes.items[to_index].?;

        // Go through all components from the 'from' archetype and move it to the 'to' archetype.
        var map_iter = from.*.?.components.iterator();
        const entity_info: *EntityArche = &self.*.entity_info.items[safe_entity].state;
        const old_entity_packed_idx : ?usize = entity_info.*.Alive.packed_idx;
        while (map_iter.next()) |item| {
            const key = item.key_ptr.*;
            const value: *ComponentStorageErased = item.value_ptr;

            // If the 'to' archetype has this component, take from!
            if(to.*.components.getPtr(key)) | to_component_storage| {
                try to_component_storage.*.take_from(to_component_storage, value, old_entity_packed_idx.?);
                entity_info.*.Alive.packed_idx = to_component_storage.*.len(to_component_storage) - 1; // Redundent.

            }else {
                // If the 'to' archetype doesn't have this archetype, reduce the array size by one.
                try value.*.swap_del(value, old_entity_packed_idx.?);
            }
        }
        // Remove 1 entity from the archetype!
        from.*.?.entity_count -= 1;
        to.*.entity_count += 1;

        if (from.*.?.entity_count == 0 and from_index != 0) { // from_index != 0 -> Don't make the 'Empty Archetype' null ever! It will always be...
            from.* = null;
        }

        // All of the following steps could be in the above while loop, except that it would do the same thing many times.
        // Instead, we'll find what it needs to do and do it once.

        // We know that all of this data will be put at the end of to_component_storage.
        // Now update the sparse set and stuff!
        entity_info.*.Alive.archetype_idx = to_index;

        // Update entity info for the two entities.
        if(from.* != null and from_index != 0 and (old_entity_packed_idx.? != from.*.?.entity_count)){
            // Update the entity we moved in the 'from' archetype. This is needed because we used the 'swapRemove' function.
            // TODO: Get rid of this garbage. Store the entity information right next to each component.
            if (self.*.find_entity(from_index, from.*.?.entity_count)) |moved_entity| {
                self.*.entity_info.items[moved_entity.entity_id].state.Alive.packed_idx = old_entity_packed_idx.?;
            } else {
                unreachable; // Oh boy, we lost that one entity we moved...
            }
        } else { // The entity we just moved was the last entity in this archetype.
            // Do nothing, just room for comments.
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
            var archetype: *Archetype = &(archetype_opt.* orelse continue);
            if (archetype.*.components.count() != arch_component_names.len + 1) continue;

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
            const arch_component_types: []ComponentStorageErased = try self.*.ecs_config.component_allocator.alloc(ComponentStorageErased, arch_component_names.len + 1);
            defer self.*.ecs_config.component_allocator.free(arch_component_types);
            // write to the new ComponentStorages
            for (old_arch_component_types, arch_component_types[0 .. arch_component_types.len - 1]) |*component_storage, *new_component_storage| {
                new_component_storage.* = try component_storage.*.make_new(component_storage);
            }
            arch_component_types[arch_component_names.len] = try ComponentStorageErased.init(@TypeOf(comp_t), self.*.ecs_config.component_allocator);

            var new_components = try self.*.ecs_config.component_allocator.alloc([]const u8, arch_component_names.len + 1);
            defer self.*.ecs_config.component_allocator.free(new_components);

            std.mem.copyForwards([]const u8, new_components[0..new_components.len], arch_component_names);
            new_components[arch_component_names.len] = component_name;

            try self.archetypes.append(try Archetype.init(self.*.ecs_config.component_allocator, new_components, arch_component_types));
            self.*.archetype_count += 1;
            matching_arch = self.archetypes.items.len - 1;
        }
        std.debug.assert(matching_arch != null);

        const to_archetype: *Archetype = &self.*.archetypes.items[matching_arch.?].?;

        try self.move_entity_one(entity, ent_info.state.Alive.archetype_idx, matching_arch.?);

        // Finally, add the new component.
        var new_component_storage_erased: *ComponentStorageErased = to_archetype.*.components.getPtr(component_name).?;
        var new_component_storage: *ComponentStorage(@TypeOf(comp_t)) = new_component_storage_erased.*.cast(@TypeOf(comp_t));
        try new_component_storage.*.packed_set.append(comp_t);

        // Is the to_archetype the "Empty Archetype"?
        if (ent_info.state.Alive.archetype_idx == 0) {
            // If it is, update the packed set index to reflect it.
            self.*.entity_info.items[safe_entity].state.Alive.packed_idx = new_component_storage.*.packed_set.items.len - 1;
        }
    }

    // TODO: Return pointer to data
    pub fn get_component(self: *Self, entity: Entity, component_name: []const u8, comptime component_type: type) !?*component_type {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        const arche_info: EntityArche = self.*.entity_info.items[safe_entity].state;


        if (self.*.archetypes.items[arche_info.Alive.archetype_idx].?.components.getPtr(component_name)) |component_storage_unwrap| {
            var component_storage: *ComponentStorage(component_type) = component_storage_unwrap.*.cast(component_type);
            if(component_storage.*.packed_set.items.len <= arche_info.Alive.packed_idx.?) {
                @panic("Out of bounds reading\n");
            }
            return &component_storage.*.packed_set.items[arche_info.Alive.packed_idx.?];
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

        if (current_archetype.*.components.count() == 1) {
            // Simply move this entity to the 'Empty Architecture'
            try self.*.move_entity_one(entity, current_archetype_idx, 0);
            // I don't think there is any cleanup.
            entity_info.*.state.Alive.archetype_idx = 0;
            entity_info.*.state.Alive.packed_idx = null;
        } else {
            // Make a new array of component names that will contain all of the names of the components
            // this entity has *except* for 'component_name', as we are deleting that one.
            var component_query: [][]const u8 = try self.*.ecs_config.component_allocator.alloc([]const u8, current_archetype.*.components.count() - 1);
            defer self.*.ecs_config.component_allocator.free(component_query);

            const current_components: [][]const u8 = current_archetype.*.components.keys();
            //Find where the component to be removed is in the current_components.
            const removing_component: usize = for (0.., current_components) |index, component| {
                if (std.mem.eql(u8, component, component_name)) {
                    break index;
                }
            } else {
                unreachable;
            };

            @memcpy(component_query, current_components[0..removing_component]);
            if (removing_component != current_archetype.components.count()) { // I dunno what would happen if I didn't have this...
                @memcpy(component_query[removing_component..], current_components[removing_component + 1 ..]);
            }

            // find an archetype that matches the 'component_query'. Then
            for (0.., self.*.archetypes.items) |index, *item| {
                var archetype: *Archetype = &item.*.?;
                if (archetype.*.compare(component_query) == true) {
                    // This archetype is the guy.
                    try self.*.move_entity_one(entity, current_archetype_idx, index);
                    break;
                }
            } else {
                // There is no archetype that has this set of components, create a new one.
                var component_storage: []ComponentStorageErased = try self.*.ecs_config.component_allocator.alloc(ComponentStorageErased, component_query.len);

                // Use the component storages from the 'from' archetype to create the component storages we need for the 'to' archetype.
                for (component_query, component_storage) |component, *item| {
                    var component_storage_er: *ComponentStorageErased = current_archetype.*.components.getPtr(component).?;
                    item.* = try component_storage_er.*.make_new(component_storage_er);
                }

                // TODO: make this fill holes rather than just append.
                try self.*.archetypes.append(try Archetype.init(self.*.ecs_config.component_allocator, component_query, component_storage));
                self.*.archetype_count += 1;

                // Move entity.
                try self.*.move_entity_one(entity, current_archetype_idx, self.*.archetype_count - 1);
            }
        }
    }

    // TODO: Maybe remove this, as get_component would return a pointer.
    pub fn write_component(self: *Self, entity: Entity, component_name: []const u8, data: anytype) !void {
        const safe_entity: usize = try self.*.unwrap_entity(entity);
        var entity_info: *EntityInfo = &self.*.entity_info.items[safe_entity];
        var archetype: *Archetype = &(self.*.archetypes.items[entity_info.*.state.Alive.archetype_idx] orelse unreachable);
        var component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(component_name) orelse return ECSError.EntityDoesNotHaveComponent;
        var component_storage: *ComponentStorage(@TypeOf(data)) = component_storage_erased.*.cast(@TypeOf(data));
        component_storage.*.packed_set.items[entity_info.state.Alive.packed_idx.?] = data;
    }

    pub fn kill_entity(self : *Self, entity : Entity) !void {
        const safe_entity : usize = try self.*.unwrap_entity(entity);
        
        // Find the archetype the entity belongs too.
        // move to the "Empty Archetype"
        const arche_idx = self.*.entity_info.items[safe_entity].state.Alive.archetype_idx;

        try self.move_entity(entity, arche_idx, 0);
        
        self.*.archetypes.items[0].?.entity_count -= 1; // This archetype has no data to wrestle (yay!)

        var entity_info = &self.*.entity_info.items[safe_entity];
        entity_info.*.version += 1;
        entity_info.*.state = .Dead;
    }
};

pub fn data_iter(comptime components: anytype) type {
    const desc_type = @TypeOf(components); // Type of the input object.
    const desc_type_info: std.builtin.Type.Struct = @typeInfo(desc_type).Struct; // Type information on the input type.

    // These are the component names and component types the user has provided.
    var field_names: [desc_type_info.fields.len][]const u8 = undefined;
    comptime var field_types: [desc_type_info.fields.len]type = undefined;

    // Go populate the above things.
    inline for (0.., desc_type_info.fields) |index, field| {
        field_names[index] = field.name;
        const field_type: type = @field(components, field.name);
        field_types[index] = field_type;
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

    // This type describes one iteration of the slicing process.
    // Each field is one of the component names, like .meatbag, .transform, or such.
    // Within each of those is all of the fields of the component, except a pointer to it.
    var fields: [desc_type_info.fields.len + 1]std.builtin.Type.StructField = undefined;
    for (fields[0..desc_type_info.fields.len], field_names, field_types) |*field, field_name, field_type| {
        field.*.name = field_name;
        field.*.type = @Type(.{
            .Pointer = .{
                .size = std.builtin.Type.Pointer.Size.One,
                .is_const = false,
                .is_volatile = false,
                .alignment = 8,
                .address_space = std.builtin.AddressSpace.generic,
                .child = field_type, // This is very important!
                .is_allowzero = false,
                .sentinel = null,
            },
        });
        field.*.alignment = 0;
        field.*.is_comptime = false;
        field.*.default_value = null;
    }
    fields[desc_type_info.fields.len] = std.builtin.Type.StructField{ .name = "entity", .type = Entity, .alignment = 0, .is_comptime = false, .default_value = null };
    const slice_type = @Type(.{ .Struct = .{ .layout = .Auto, .fields = fields[0..], .decls = &[_]std.builtin.Type.Declaration{}, .is_tuple = false } });

    const slice_type_info: std.builtin.Type.Struct = @typeInfo(slice_type).Struct;

    const baked_names: [desc_type_info.fields.len][]const u8 = field_names;

    // This huge for loop will get the sum of the component's fields.
    var slice_member_offsets: [desc_type_info.fields.len]usize = undefined;
    var component_field_ptr_funcs: [desc_type_info.fields.len]*const fn (*ComponentStorageErased) *anyopaque = undefined;
    var component_field_iter_funcs: [desc_type_info.fields.len]*const fn (*ComponentStorageErased, usize) *anyopaque = undefined;
    inline for (0.., slice_type_info.fields[0..desc_type_info.fields.len]) |index, field| {
        const field_offset = @offsetOf(slice_type, field.name);
        slice_member_offsets[index] = field_offset;

        const field_type: type = find_type(@constCast(baked_names[0..]), @constCast(field_types[0..]), field.name);
        component_field_ptr_funcs[index] = ComponentStorageErased.get_field_ptr(field_type);
        component_field_iter_funcs[index] = ComponentStorageErased.anon_index(field_type);
    }

    const baked_offsets = slice_member_offsets;
    const baked_component_funcs = component_field_ptr_funcs;
    const baked_component_iter_funcs = component_field_iter_funcs;

    // Iterate through slice_type, storing offsets.

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
            // std.log.debug("First Archetype : {?}", .{first_archetype});

            return .{ .archetype_idx = first_archetype, .packed_idx = null, .ecs = ecs, .slice = undefined };
        }

        pub fn next(self: *@This()) ?slice_type {
            // std.log.debug("Iteration : archetype_idx : {?}", .{self.*.archetype_idx});
            if (self.*.archetype_idx == null) return null;
            const safe_archetype_idx: usize = self.*.archetype_idx.?;
            var archetype: *Archetype = &self.*.ecs.*.archetypes.items[safe_archetype_idx].?;

            // std.log.debug("Packed index : {?}", .{self.*.packed_idx});
            if (self.*.packed_idx == null) {
                //TODO: if this archetype does not have any component (assert, this shouldn't happen) then iterate to the next archetype.
                for (baked_names, baked_offsets, baked_component_funcs) |component_name, offset, func| {
                    var component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(component_name).?;
                    @as(**anyopaque, @ptrFromInt(@intFromPtr(&self.*.slice) + offset)).* = func(component_storage_erased);
                }
                self.*.packed_idx = 0;
            } else {
                // Already started iterating
                self.*.packed_idx = self.*.packed_idx.? + 1;
                var done_iter_count: usize = 0;
                for (baked_names, baked_offsets, baked_component_iter_funcs) |component_name, offset, func| {
                    var component_storage_erased: *ComponentStorageErased = archetype.*.components.getPtr(component_name).?;
                    if (self.*.packed_idx.? >= component_storage_erased.*.len(component_storage_erased)) {
                        done_iter_count += 1;
                        continue;
                    }

                    var component_iter: **anyopaque = @ptrFromInt(@intFromPtr(&self.*.slice) + offset);
                    const iteration_res = func(component_storage_erased, self.*.packed_idx.?);
                    component_iter.* = iteration_res;
                }

                // if there are any component storages that are done iterating, make sure they all are!
                if (done_iter_count > 0) {
                    std.debug.assert(done_iter_count == desc_type_info.fields.len);

                    // Because these are all done iterating, time to go to the next archetype.
                    self.*.packed_idx = null;
                    self.*.archetype_idx = self.*.archetype_idx.? + 1;
                    while (self.*.archetype_idx.? < self.*.ecs.archetype_count) {
                        const archetype_maybe: *?Archetype = &self.*.ecs.archetypes.items[self.*.archetype_idx.?];
                        var iter_archetype: *Archetype = &(archetype_maybe.* orelse {
                            self.*.archetype_idx = self.*.archetype_idx.? + 1;
                            continue;
                        });
                        if (iter_archetype.*.contains(@constCast(baked_names[0..]))) {
                            return self.next();
                        }
                        self.*.archetype_idx = self.*.archetype_idx.? + 1;
                    } else {
                        // A little more magic, if there are no more archetypes, return null!
                        return null;
                    }
                }
            }
            self.*.slice.entity = self.*.ecs.find_entity(safe_archetype_idx, self.*.packed_idx);
            return self.*.slice;
        }
    };
    
}