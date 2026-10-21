package ch44sm

import "core:fmt"
import "core:strings"

emit_program :: proc(tctx: ^Asm_Context) -> (success: bool) {
	current_global_label: string
	has_errors: bool

	text_buf := make([dynamic]u8, context.temp_allocator)
	data_buf := make([dynamic]u8, context.temp_allocator)

	tctx.current_section = .Text
	program_len := u16(tctx.section_pcs[.Text])
	tctx.section_pcs[.Text] = 0
	tctx.section_pcs[.Data] = 0

	stmt_loop: for &stmt in tctx.program {
		#partial switch &s in stmt {
		case Directive_Decl:
			directive := s
			#partial switch directive.kind {
			case .Text:
				tctx.current_section = .Text
			case .Data:
				tctx.current_section = .Data
			case .Ascii:
				for arg in directive.args {
					if str, is_str := arg.(string); is_str {
						for i in 0 ..< len(str) {
							append(&data_buf, str[i])
						}
					}
				}
			case .Byte:
				for arg in directive.args {
					if imm, is_imm := arg.(int); is_imm {
						append(&data_buf, u8(imm))
					}
				}
			case .Word:
				for arg in directive.args {
					if imm, is_imm := arg.(int); is_imm {
						append(&data_buf, u8(imm >> 8))
						append(&data_buf, u8(imm & 0xFF))
					}
				}
			}
		case Label_Decl:
			label := s
			if !label.is_local {
				current_global_label = label.raw_name
			}
		case Instruction_Decl:
			instruction := &s
			for i in 0 ..< instruction.op_count {
				op := &instruction.operands[i]

				#partial switch &op_val in op {
				case Label:
					op_label := &op_val

					target_label: string
					is_local: bool

					if strings.has_prefix(op_label.raw_name, ".") {
						target_label = fmt.aprintf(
							"%s$%s",
							current_global_label,
							op_label.raw_name,
						)
						is_local = true
					} else {
						target_label = op_label.raw_name
					}

					symbol_info, exists := tctx.symbol_table[target_label]
					if exists {
						op_label.resolved_address = u16(symbol_info.offset)
						if symbol_info.section == .Data do op_label.resolved_address += program_len
						symbol_info.uses += 1
						tctx.symbol_table[target_label] = symbol_info
					} else {
						append(&tctx.diagnostics, {
							code = .Sem_Undefined_Label,
							loc = op_label.loc,
							message = "Undefined reference to label",
							label = "undefined label here",
							hint = "ensure the label is defined in this file and check for typos.",
						})
						has_errors = true
						continue stmt_loop
					}
				}
			}
			emit_instruction(&text_buf, instruction)
		}
	}

	append(&tctx.bytecode, ..text_buf[:])
	append(&tctx.bytecode, ..data_buf[:])

	if !has_errors {
		check_unused_labels(tctx)
	}

	free_all(context.temp_allocator)
	return !has_errors
}

emit_opcode :: #force_inline proc(buf: ^[dynamic]u8, opcode: u16) {
	append(buf, u8(opcode >> 8), u8(opcode & 0xFF))
}

emit_instruction :: proc(buf: ^[dynamic]u8, instruction: ^Instruction_Decl) {
	switch instruction.kind {
	case .Ret: emit_opcode(buf, 0x00EE)
	case .Cls: emit_opcode(buf, 0x00E0)
	case .Skey:
		r := u16(instruction.operands[0].(Register))
		emit_opcode(buf, 0xE09E | (r << 8))
	case .Snkey:
		r := u16(instruction.operands[0].(Register))
		emit_opcode(buf, 0xE0A1 | (r << 8))
	case .Wkey:
		r := u16(instruction.operands[0].(Register))
		emit_opcode(buf, 0xE00A | (r << 8))
	case .J:
		addr := (u16)(instruction.operands[0].(Label).resolved_address)
		emit_opcode(buf, 0x1000 | addr)
	case .Call:
		addr := (u16)(instruction.operands[0].(Label).resolved_address)
		emit_opcode(buf, 0x2000 | addr)
	case .Mv:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8000 | (r1 << 8) | (r2 << 4))
	case .Seq:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x5000 | (r1 << 8) | (r2 << 4))
	case .Sne:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x9000 | (r1 << 8) | (r2 << 4))
	case .Add:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8004 | (r1 << 8) | (r2 << 4))
	case .Sub:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8005 | (r1 << 8) | (r2 << 4))
	case .Subn:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8007 | (r1 << 8) | (r2 << 4))
	case .Or:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8001 | (r1 << 8) | (r2 << 4))
	case .And:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8002 | (r1 << 8) | (r2 << 4))
	case .Xor:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8003 | (r1 << 8) | (r2 << 4))
	case .Add_P:
		r := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0xF01E | (r << 8))
	case .La_Font:
		r := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0xF029 | (r << 8))
	case .Sbcd:
		r := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0xF033 | (r << 8))
	case .Tm_R:
		r := u16(instruction.operands[0].(Register))
		emit_opcode(buf, 0xF007 | (r << 8))
	case .Tm_W:
		r := u16(instruction.operands[1].(Register))
		#partial switch instruction.operands[0].(Register) {
		case .Dt: emit_opcode(buf, 0xF015 | (r << 8))
		case .St: emit_opcode(buf, 0xF018 | (r << 8))
		}
	case .Li:
		r := u16(instruction.operands[0].(Register))
		imm := (u16)(instruction.operands[1].(int))
		emit_opcode(buf, 0x6000 | (r << 8) | imm)
	case .Rnd:
		r := u16(instruction.operands[0].(Register))
		imm := (u16)(instruction.operands[1].(int))
		emit_opcode(buf, 0xC000 | (r << 8) | imm)
	case .Seqi:
		r := u16(instruction.operands[0].(Register))
		imm := (u16)(instruction.operands[1].(int))
		emit_opcode(buf, 0x3000 | (r << 8) | imm)
	case .Snei:
		r := u16(instruction.operands[0].(Register))
		imm := (u16)(instruction.operands[1].(int))
		emit_opcode(buf, 0x4000 | (r << 8) | imm)
	case .Addi:
		r := u16(instruction.operands[0].(Register))
		imm := (u16)(instruction.operands[1].(int))
		emit_opcode(buf, 0x7000 | (r << 8) | imm)
	case .La:
		addr := (u16)(instruction.operands[1].(Label).resolved_address)
		emit_opcode(buf, 0xA000 | addr)
	case .Jdx:
		addr := (u16)(instruction.operands[0].(Label).resolved_address)
		r := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0xB000 | addr + r)
	case .Sr:
		r := u16(instruction.operands[2].(Register))
		emit_opcode(buf, 0xF055 | (r << 8))
	case .Lr:
		r := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0xF065 | (r << 8))
	case .Mv_Sll:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x800E | (r1 << 8) | (r2 << 4))
	case .Mv_Srl:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		emit_opcode(buf, 0x8006 | (r1 << 8) | (r2 << 4))
	case .Draw:
		r1 := u16(instruction.operands[0].(Register))
		r2 := u16(instruction.operands[1].(Register))
		imm := (u16)(instruction.operands[2].(int))
		emit_opcode(buf, 0xD000 | (r1 << 8) | (r2 << 4) | imm)
	case .Invalid:
	}
}

check_unused_labels :: proc(tctx: ^Asm_Context) {
	for name, info in tctx.symbol_table {
		if name == "_start" do continue
		if info.uses > 0 do continue

		append(
			&tctx.diagnostics,
			{
				code = .Wrn_Unused_Label,
				loc = info.loc,
				message = fmt.aprintf("Label '%s' is defined but never used", name),
				label = "unused label",
				hint = "if this label is no longer needed, you can safely remove it to clean up the code",
			},
		)
	}
}
