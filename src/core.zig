const std = @import("std");
const Op = @import("op.zig");

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    memory: u32 = 0,
    funcs: []Func,
    exports: []Export,

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
        self.funcs = &[0]Func{};
        self.exports = &[0]Export{};
    }

    pub const Type = enum {
        I32,
        I64,
        F32,
        F64,
    };

    pub const Export = struct {
        name: []const u8,
        value: union(enum) {
            func: usize,
        },
    };

    pub const Func = struct {
        name: ?[]const u8,
        params: []Type,
        result: ?Type,
        locals: []Type,
        instrs: []Instr,
    };

    pub const Instr = struct {
        opcode: u8,
        arg: Op.Arg,
    };
};

pub const WasmTrap = error{
    Unreachable,
    Overflow,
    OutOfBounds,
    DivisionByZero,
    InvalidConversionToInteger,
};

pub const Value = union {
    I32: i32,
    I64: i64,
    F32: f32,
    F64: f64,
};

pub const Instance = struct {
    module: *Module,
    memory: []u8,
    allocator: *std.mem.Allocator,

    // TODO: revisit if wasm ever becomes multi-threaded
    mutex: std.Mutex,

    fn call(instance: *Instance, name: []const u8, params: []Module.Type) !Value {
        const lock = self.mutex.acquire();
        defer lock.release();

        var stack: [1 << 10]u8 = undefined;
        ExecutionContext.run(self, &stack, name, params);
    }

    // TODO: move these to a function execution context
    locals: StackLookup,
    globals: StackLookup,

    const StackLookup = struct {
        memory: []u8,
        lookup_meta: []struct {
            offset: usize,
            typ: Module.Type,
        },

        pub fn get(self: StackLookup, num: usize) Value {
            const meta = self.lookup_meta[num];
            return switch (meta.typ) {
                .I32 => .{ .I32 = std.mem.readIntLittle(i32, self.ptr32(meta.offset)) },
                .I64 => .{ .I64 = std.mem.readIntLittle(i64, self.ptr64(meta.offset)) },
                .F32 => .{ .F32 = std.mem.readIntLittle(f32, self.ptr32(meta.offset)) },
                .F64 => .{ .F64 = std.mem.readIntLittle(f64, self.ptr64(meta.offset)) },
            };
        }

        pub fn set(self: StackLookup, num: usize, value: Value) void {
            const meta = self.lookup_meta[num];
            switch (meta.typ) {
                .I32 => std.mem.writeIntLittle(i32, self.ptr32(meta.offset), value.I32),
                .I64 => std.mem.writeIntLittle(i64, self.ptr64(meta.offset), value.I64),
                .F32 => std.mem.writeIntLittle(f32, self.ptr32(meta.offset), value.F32),
                .F64 => std.mem.writeIntLittle(f64, self.ptr64(meta.offset), value.F64),
            }
        }

        fn ptr32(self: StackLookup, offset: usize) *[4]u8 {
            return @ptrCast(*[4]u8, &self.memory[offset]);
        }

        fn ptr64(self: StackLookup, offset: usize) *[8]u8 {
            return @ptrCast(*[8]u8, &self.memory[offset]);
        }
    };

    pub fn memGet(self: Instance, start: usize, offset: usize, comptime length: usize) !*[length]u8 {
        const tail = start +% offset +% (length - 1);
        const is_overflow = tail < start;
        const is_seg_fault = tail >= self.memory.len;
        if (is_overflow or is_seg_fault) {
            return error.OutOfBounds;
        }
        return @ptrCast(*[length]u8, &self.memory[start + offset]);
    }
};

pub const ExecutionContext = struct {
    instance: *Instance,
    stack: []u8,
    stack_top: usize,

    current_frame: Frame,

    const Frame = struct {
        func: Index.Func,
        instr: Index.Instr,
        top: usize,

        const Serialized = packed struct {
            func: u20, // "max size" of 1000000
            instr: u22, // "max size" of 7654321 assuming average instruction size of 2 bytes
            top: u22, // 4 million addressable space == 16MB
        };

        fn restore(raw: Serialized) Frame {
            return .{
                .func = @intToEnum(Index.Func, raw.func),
                .instr = @intToEnum(Index.Instr, raw.instr),
                .top = raw.top,
            };
        }

        fn dump(self: Frame) Serialized {
            return .{
                .func = @enumToInt(self.func),
                .instr = @enumToInt(self.instr),
                .top = self.top,
            };
        }

        fn terminus() Frame {
            return .{ .func = 0, .instr = 0, .top = 0 };
        }

        fn isTerminus(self: Frame) bool {
            return self.func == 0 and self.instr == 0 and self.top == 0;
        }
    };

    fn run(instance: *Instance, stack: []u8, func_name: []const u8, params: []Module.Type) void {
        var ctx = ExecutionContext{
            .instance = instance,
            .stack = stack,
            .stack_top = stack.len,
            .current_frame = Frame.terminus(),
        };

        // Internal calls assume the arguments already exist
        for (params) |param| {
            ctx.push(param);
        }

        ctx.call(id);
    }

    fn call(self: *ExecutionContext, func_id: Index.Function) void {
        const func = self.instance.funcs[func_id];
        // TODO: validate params on the callstack
        for (func.locals) |local| {
            switch (local) {
                .I32 => self.push(i32, undefined),
                .I64 => self.push(i64, undefined),
                .F32 => self.push(f32, undefined),
                .F64 => self.push(f64, undefined),
            }
        }

        self.push(Frame, self.current_frame);
        self.current_frame = .{
            .func = func_id,
            .instr = 0,
            .top = self.stack_top,
        };

        // TODO: this loop should be in `run()`
        // We should be able to flatten this call stack and have no dynamic stack requirements
        for (func.instrs) |instr, i| {
            self.current_frame.instr = i;
            // Run
        }

        const result = self.pop(func.return_type);
        self.unwindCall(func.return_value, result);
    }

    fn unwindCall(self: *ExecutionContext, func: Func, result: var) void {
        self.stack_top = self.current_frame.top;

        const prev_frame = Frame.restore(self.pop(Frame.Serialized));
        self.dropBytes(func.local_size + func.param_size);

        if (prev_frame.isTerminus()) {
            std.debug.assert(self.stack_top == self.stack.len);
            // THE END!
        }
    }

    fn dropBytes(self: *ExecutionContext, size: usize) void {
        std.debug.assert(self.stack_top + size <= stack.len);
        self.stack_top += size;
    }

    fn pop(self: *ExecutionContext, comptime T: type) T {
        self.curr_size -= @sizeOf(T);
        defer self.top += @sizeOf(T);
        return std.mem.bytesToValue(T, &self.memory[self.top]);
    }

    fn push(self: *ExecutionContext, comptime T: type, value: T) !void {
        self.top = try std.math.sub(self.top, @sizeOf(T));
        self.curr_size += @sizeOf(T);
        std.mem.copy(u8, self.memory[self.top..0], std.mem.toBytes(value));
    }
};
