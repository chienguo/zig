//! This file contains the functionality for lowering SPARCv9 MIR into
//! machine code

const std = @import("std");
const Endian = std.builtin.Endian;
const assert = std.debug.assert;
const link = @import("../../link.zig");
const Module = @import("../../Module.zig");
const ErrorMsg = Module.ErrorMsg;
const Liveness = @import("../../Liveness.zig");
const log = std.log.scoped(.sparcv9_emit);
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;
const DW = std.dwarf;
const leb128 = std.leb;

const Emit = @This();
const Mir = @import("Mir.zig");
const bits = @import("bits.zig");
const Instruction = bits.Instruction;
const Register = bits.Register;

mir: Mir,
bin_file: *link.File,
debug_output: DebugInfoOutput,
target: *const std.Target,
err_msg: ?*ErrorMsg = null,
src_loc: Module.SrcLoc,
code: *std.ArrayList(u8),

prev_di_line: u32,
prev_di_column: u32,
/// Relative to the beginning of `code`.
prev_di_pc: usize,

/// The branch type of every branch
branch_types: std.AutoHashMapUnmanaged(Mir.Inst.Index, BranchType) = .{},
/// For every forward branch, maps the target instruction to a list of
/// branches which branch to this target instruction
branch_forward_origins: std.AutoHashMapUnmanaged(Mir.Inst.Index, std.ArrayListUnmanaged(Mir.Inst.Index)) = .{},
/// For backward branches: stores the code offset of the target
/// instruction
///
/// For forward branches: stores the code offset of the branch
/// instruction
code_offset_mapping: std.AutoHashMapUnmanaged(Mir.Inst.Index, usize) = .{},

const InnerError = error{
    OutOfMemory,
    EmitFail,
};

const BranchType = enum {
    bpcc,
    fn default(tag: Mir.Inst.Tag) BranchType {
        return switch (tag) {
            .bpcc => .bpcc,
            else => unreachable,
        };
    }
};

pub fn emitMir(
    emit: *Emit,
) InnerError!void {
    const mir_tags = emit.mir.instructions.items(.tag);

    // Convert absolute addresses into offsets and
    // find smallest lowerings for branch instructions
    try emit.lowerBranches();

    // Emit machine code
    for (mir_tags) |tag, index| {
        const inst = @intCast(u32, index);
        switch (tag) {
            .dbg_line => try emit.mirDbgLine(inst),
            .dbg_prologue_end => try emit.mirDebugPrologueEnd(),
            .dbg_epilogue_begin => try emit.mirDebugEpilogueBegin(),

            .add => try emit.mirArithmetic3Op(inst),

            .bpcc => try emit.mirConditionalBranch(inst),

            .call => @panic("TODO implement sparc64 call"),

            .jmpl => try emit.mirArithmetic3Op(inst),

            .ldub => try emit.mirArithmetic3Op(inst),
            .lduh => try emit.mirArithmetic3Op(inst),
            .lduw => try emit.mirArithmetic3Op(inst),
            .ldx => try emit.mirArithmetic3Op(inst),

            .@"or" => try emit.mirArithmetic3Op(inst),

            .nop => try emit.mirNop(),

            .@"return" => try emit.mirArithmetic2Op(inst),

            .save => try emit.mirArithmetic3Op(inst),
            .restore => try emit.mirArithmetic3Op(inst),

            .sethi => try emit.mirSethi(inst),

            .sllx => @panic("TODO implement sparc64 sllx"),

            .stb => try emit.mirArithmetic3Op(inst),
            .sth => try emit.mirArithmetic3Op(inst),
            .stw => try emit.mirArithmetic3Op(inst),
            .stx => try emit.mirArithmetic3Op(inst),

            .sub => try emit.mirArithmetic3Op(inst),
            .subcc => try emit.mirArithmetic3Op(inst),

            .tcc => try emit.mirTrap(inst),
        }
    }
}

pub fn deinit(emit: *Emit) void {
    var iter = emit.branch_forward_origins.valueIterator();
    while (iter.next()) |origin_list| {
        origin_list.deinit(emit.bin_file.allocator);
    }

    emit.branch_types.deinit(emit.bin_file.allocator);
    emit.branch_forward_origins.deinit(emit.bin_file.allocator);
    emit.code_offset_mapping.deinit(emit.bin_file.allocator);
    emit.* = undefined;
}

fn mirDbgLine(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const dbg_line_column = emit.mir.instructions.items(.data)[inst].dbg_line_column;

    switch (tag) {
        .dbg_line => try emit.dbgAdvancePCAndLine(dbg_line_column.line, dbg_line_column.column),
        else => unreachable,
    }
}

fn mirDebugPrologueEnd(emit: *Emit) !void {
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_prologue_end);
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirDebugEpilogueBegin(emit: *Emit) !void {
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_epilogue_begin);
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirArithmetic2Op(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const data = emit.mir.instructions.items(.data)[inst].arithmetic_2op;

    const rs1 = data.rs1;

    if (data.is_imm) {
        const imm = data.rs2_or_imm.imm;
        switch (tag) {
            .@"return" => try emit.writeInstruction(Instruction.@"return"(i13, rs1, imm)),
            else => unreachable,
        }
    } else {
        const rs2 = data.rs2_or_imm.rs2;
        switch (tag) {
            .@"return" => try emit.writeInstruction(Instruction.@"return"(Register, rs1, rs2)),
            else => unreachable,
        }
    }
}

fn mirArithmetic3Op(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const data = emit.mir.instructions.items(.data)[inst].arithmetic_3op;

    const rd = data.rd;
    const rs1 = data.rs1;

    if (data.is_imm) {
        const imm = data.rs2_or_imm.imm;
        switch (tag) {
            .add => try emit.writeInstruction(Instruction.add(i13, rs1, imm, rd)),
            .jmpl => try emit.writeInstruction(Instruction.jmpl(i13, rs1, imm, rd)),
            .ldub => try emit.writeInstruction(Instruction.ldub(i13, rs1, imm, rd)),
            .lduh => try emit.writeInstruction(Instruction.lduh(i13, rs1, imm, rd)),
            .lduw => try emit.writeInstruction(Instruction.lduw(i13, rs1, imm, rd)),
            .ldx => try emit.writeInstruction(Instruction.ldx(i13, rs1, imm, rd)),
            .@"or" => try emit.writeInstruction(Instruction.@"or"(i13, rs1, imm, rd)),
            .save => try emit.writeInstruction(Instruction.save(i13, rs1, imm, rd)),
            .restore => try emit.writeInstruction(Instruction.restore(i13, rs1, imm, rd)),
            .stb => try emit.writeInstruction(Instruction.stb(i13, rs1, imm, rd)),
            .sth => try emit.writeInstruction(Instruction.sth(i13, rs1, imm, rd)),
            .stw => try emit.writeInstruction(Instruction.stw(i13, rs1, imm, rd)),
            .stx => try emit.writeInstruction(Instruction.stx(i13, rs1, imm, rd)),
            .sub => try emit.writeInstruction(Instruction.sub(i13, rs1, imm, rd)),
            .subcc => try emit.writeInstruction(Instruction.subcc(i13, rs1, imm, rd)),
            else => unreachable,
        }
    } else {
        const rs2 = data.rs2_or_imm.rs2;
        switch (tag) {
            .add => try emit.writeInstruction(Instruction.add(Register, rs1, rs2, rd)),
            .jmpl => try emit.writeInstruction(Instruction.jmpl(Register, rs1, rs2, rd)),
            .ldub => try emit.writeInstruction(Instruction.ldub(Register, rs1, rs2, rd)),
            .lduh => try emit.writeInstruction(Instruction.lduh(Register, rs1, rs2, rd)),
            .lduw => try emit.writeInstruction(Instruction.lduw(Register, rs1, rs2, rd)),
            .ldx => try emit.writeInstruction(Instruction.ldx(Register, rs1, rs2, rd)),
            .@"or" => try emit.writeInstruction(Instruction.@"or"(Register, rs1, rs2, rd)),
            .save => try emit.writeInstruction(Instruction.save(Register, rs1, rs2, rd)),
            .restore => try emit.writeInstruction(Instruction.restore(Register, rs1, rs2, rd)),
            .stb => try emit.writeInstruction(Instruction.stb(Register, rs1, rs2, rd)),
            .sth => try emit.writeInstruction(Instruction.sth(Register, rs1, rs2, rd)),
            .stw => try emit.writeInstruction(Instruction.stw(Register, rs1, rs2, rd)),
            .stx => try emit.writeInstruction(Instruction.stx(Register, rs1, rs2, rd)),
            .sub => try emit.writeInstruction(Instruction.sub(Register, rs1, rs2, rd)),
            .subcc => try emit.writeInstruction(Instruction.subcc(Register, rs1, rs2, rd)),
            else => unreachable,
        }
    }
}

fn mirConditionalBranch(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const branch_predict_int = emit.mir.instructions.items(.data)[inst].branch_predict_int;

    const offset = @intCast(i64, emit.code_offset_mapping.get(branch_predict_int.inst).?) - @intCast(i64, emit.code.items.len);
    const branch_type = emit.branch_types.get(inst).?;
    log.debug("mirConditionalBranchImmediate: {} offset={}", .{ inst, offset });

    switch (branch_type) {
        .bpcc => switch (tag) {
            .bpcc => try emit.writeInstruction(Instruction.bpcc(branch_predict_int.cond, branch_predict_int.annul, branch_predict_int.pt, branch_predict_int.ccr, @intCast(i21, offset))),
            else => unreachable,
        },
    }
}

fn mirNop(emit: *Emit) !void {
    try emit.writeInstruction(Instruction.nop());
}

fn mirSethi(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const data = emit.mir.instructions.items(.data)[inst].sethi;

    const imm = data.imm;
    const rd = data.rd;

    assert(tag == .sethi);
    try emit.writeInstruction(Instruction.sethi(imm, rd));
}

fn mirTrap(emit: *Emit, inst: Mir.Inst.Index) !void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    const data = emit.mir.instructions.items(.data)[inst].trap;

    const cond = data.cond;
    const ccr = data.ccr;
    const rs1 = data.rs1;

    if (data.is_imm) {
        const imm = data.rs2_or_imm.imm;
        switch (tag) {
            .tcc => try emit.writeInstruction(Instruction.trap(u7, cond, ccr, rs1, imm)),
            else => unreachable,
        }
    } else {
        const rs2 = data.rs2_or_imm.rs2;
        switch (tag) {
            .tcc => try emit.writeInstruction(Instruction.trap(Register, cond, ccr, rs1, rs2)),
            else => unreachable,
        }
    }
}

// Common helper functions

fn branchTarget(emit: *Emit, inst: Mir.Inst.Index) Mir.Inst.Index {
    const tag = emit.mir.instructions.items(.tag)[inst];

    switch (tag) {
        .bpcc => return emit.mir.instructions.items(.data)[inst].branch_predict_int.inst,
        else => unreachable,
    }
}

fn dbgAdvancePCAndLine(emit: *Emit, line: u32, column: u32) !void {
    const delta_line = @intCast(i32, line) - @intCast(i32, emit.prev_di_line);
    const delta_pc: usize = emit.code.items.len - emit.prev_di_pc;
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            // TODO Look into using the DWARF special opcodes to compress this data.
            // It lets you emit single-byte opcodes that add different numbers to
            // both the PC and the line number at the same time.
            try dbg_out.dbg_line.ensureUnusedCapacity(11);
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_pc);
            leb128.writeULEB128(dbg_out.dbg_line.writer(), delta_pc) catch unreachable;
            if (delta_line != 0) {
                dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_line);
                leb128.writeILEB128(dbg_out.dbg_line.writer(), delta_line) catch unreachable;
            }
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.copy);
            emit.prev_di_pc = emit.code.items.len;
            emit.prev_di_line = line;
            emit.prev_di_column = column;
            emit.prev_di_pc = emit.code.items.len;
        },
        else => {},
    }
}

fn fail(emit: *Emit, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(emit.err_msg == null);
    emit.err_msg = try ErrorMsg.create(emit.bin_file.allocator, emit.src_loc, format, args);
    return error.EmitFail;
}

fn instructionSize(emit: *Emit, inst: Mir.Inst.Index) usize {
    const tag = emit.mir.instructions.items(.tag)[inst];

    switch (tag) {
        .dbg_line,
        .dbg_epilogue_begin,
        .dbg_prologue_end,
        => return 0,
        // Currently Mir instructions always map to single machine instruction.
        else => return 4,
    }
}

fn isBranch(tag: Mir.Inst.Tag) bool {
    return switch (tag) {
        .bpcc => true,
        else => false,
    };
}

fn lowerBranches(emit: *Emit) !void {
    const mir_tags = emit.mir.instructions.items(.tag);
    const allocator = emit.bin_file.allocator;

    // First pass: Note down all branches and their target
    // instructions, i.e. populate branch_types,
    // branch_forward_origins, and code_offset_mapping
    //
    // TODO optimization opportunity: do this in codegen while
    // generating MIR
    for (mir_tags) |tag, index| {
        const inst = @intCast(u32, index);
        if (isBranch(tag)) {
            const target_inst = emit.branchTarget(inst);

            // Remember this branch instruction
            try emit.branch_types.put(allocator, inst, BranchType.default(tag));

            // Forward branches require some extra stuff: We only
            // know their offset once we arrive at the target
            // instruction. Therefore, we need to be able to
            // access the branch instruction when we visit the
            // target instruction in order to manipulate its type
            // etc.
            if (target_inst > inst) {
                // Remember the branch instruction index
                try emit.code_offset_mapping.put(allocator, inst, 0);

                if (emit.branch_forward_origins.getPtr(target_inst)) |origin_list| {
                    try origin_list.append(allocator, inst);
                } else {
                    var origin_list: std.ArrayListUnmanaged(Mir.Inst.Index) = .{};
                    try origin_list.append(allocator, inst);
                    try emit.branch_forward_origins.put(allocator, target_inst, origin_list);
                }
            }

            // Remember the target instruction index so that we
            // update the real code offset in all future passes
            //
            // putNoClobber may not be used as the put operation
            // may clobber the entry when multiple branches branch
            // to the same target instruction
            try emit.code_offset_mapping.put(allocator, target_inst, 0);
        }
    }

    // Further passes: Until all branches are lowered, interate
    // through all instructions and calculate new offsets and
    // potentially new branch types
    var all_branches_lowered = false;
    while (!all_branches_lowered) {
        all_branches_lowered = true;
        var current_code_offset: usize = 0;

        for (mir_tags) |tag, index| {
            const inst = @intCast(u32, index);

            // If this instruction contained in the code offset
            // mapping (when it is a target of a branch or if it is a
            // forward branch), update the code offset
            if (emit.code_offset_mapping.getPtr(inst)) |offset| {
                offset.* = current_code_offset;
            }

            // If this instruction is a backward branch, calculate the
            // offset, which may potentially update the branch type
            if (isBranch(tag)) {
                const target_inst = emit.branchTarget(inst);
                if (target_inst < inst) {
                    const target_offset = emit.code_offset_mapping.get(target_inst).?;
                    const offset = @intCast(i64, target_offset) - @intCast(i64, current_code_offset);
                    const branch_type = emit.branch_types.getPtr(inst).?;
                    const optimal_branch_type = try emit.optimalBranchType(tag, offset);
                    if (branch_type.* != optimal_branch_type) {
                        branch_type.* = optimal_branch_type;
                        all_branches_lowered = false;
                    }

                    log.debug("lowerBranches: branch {} has offset {}", .{ inst, offset });
                }
            }

            // If this instruction is the target of one or more
            // forward branches, calculate the offset, which may
            // potentially update the branch type
            if (emit.branch_forward_origins.get(inst)) |origin_list| {
                for (origin_list.items) |forward_branch_inst| {
                    const branch_tag = emit.mir.instructions.items(.tag)[forward_branch_inst];
                    const forward_branch_inst_offset = emit.code_offset_mapping.get(forward_branch_inst).?;
                    const offset = @intCast(i64, current_code_offset) - @intCast(i64, forward_branch_inst_offset);
                    const branch_type = emit.branch_types.getPtr(forward_branch_inst).?;
                    const optimal_branch_type = try emit.optimalBranchType(branch_tag, offset);
                    if (branch_type.* != optimal_branch_type) {
                        branch_type.* = optimal_branch_type;
                        all_branches_lowered = false;
                    }

                    log.debug("lowerBranches: branch {} has offset {}", .{ forward_branch_inst, offset });
                }
            }

            // Increment code offset
            current_code_offset += emit.instructionSize(inst);
        }
    }
}

fn optimalBranchType(emit: *Emit, tag: Mir.Inst.Tag, offset: i64) !BranchType {
    assert(offset & 0b11 == 0);

    switch (tag) {
        .bpcc => {
            if (std.math.cast(i21, offset)) |_| {
                return BranchType.bpcc;
            } else |_| {
                // TODO use the following strategy to implement long branches:
                // - Negate the conditional and target of the original BPcc;
                // - In the space immediately after the branch, load
                //   the address of the original target, preferrably in
                //   a PC-relative way, into %o7; and
                // - jmpl %o7 + %g0, %g0
                return emit.fail("TODO support BPcc branches larger than +-1 MiB", .{});
            }
        },
        else => unreachable,
    }
}

fn writeInstruction(emit: *Emit, instruction: Instruction) !void {
    // SPARCv9 instructions are always arranged in BE regardless of the
    // endianness mode the CPU is running in (Section 3.1 of the ISA specification).
    // This is to ease porting in case someone wants to do a LE SPARCv9 backend.
    const endian = Endian.Big;

    std.mem.writeInt(u32, try emit.code.addManyAsArray(4), instruction.toU32(), endian);
}
