package ch44sm

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

Asm_Context :: struct {
	src_path:        string,
	src:             string,
	emit_tokens:     bool,
	diagnostics:     [dynamic]Diagnostic,
	tokens:          [dynamic]Token,
	program:         ^Program,
	// Semantic
	symbol_table:    map[string]Symbol_Info,
	current_section: Section,
	section_pcs:     [Section]int,
	// Code generation
	bytecode:       [dynamic]u8,
}

Symbol_Info :: struct {
	address: int,
	section: Section,
	uses:    int,
	loc:     Source_Location,
}

Section :: enum {
	None,
	Text,
	Data,
}

Disasm_Context :: struct {
	src_path:     string,
	src:          []u8,
	org:          int,
	symbol_table: map[int]string,
	builder:      strings.Builder,
	row_addrs:   map[int]int,
}

disasm_ctx_init :: proc(
	dctx: ^Disasm_Context,
	src_path: string,
	src: []u8,
	org: int,
	allocator: mem.Allocator,

) {
	context.allocator = allocator
	dctx.src_path     = src_path
	dctx.src          = src
	dctx.org          = org
	dctx.symbol_table = make(map[int]string, context.allocator)
	strings.builder_init(&dctx.builder, context.allocator)
	dctx.row_addrs = make(map[int]int, context.allocator)
}

assemble :: proc(asm_ctx: ^Asm_Context, allocator: mem.Allocator) -> (ok: bool) {
	context.allocator = allocator

	lexer: Lexer
	lexer_init(&lexer, asm_ctx)

	parser: Parser
	parser_init(&parser, asm_ctx, &lexer)

	if !parse(&parser) do return false
	if !resolve(asm_ctx) do return false
	if !emit_program(asm_ctx) do return false

	return true
}

disassemble :: proc(disasm_ctx: ^Disasm_Context, allocator: mem.Allocator) -> string {
	context.allocator = allocator

	bytes := disasm_ctx.src
	label_counter := 0

	for i := 0; i < len(bytes); i += 2 {
		if i + 1 >= len(bytes) {
			break
		}

		opcode := (u16(bytes[i]) << 8) | u16(bytes[i + 1])
		nnn := int(opcode & 0x0FFF)
		switch opcode >> 12 {
		case 0x1, 0x2, 0xB:
			if _, exists := disasm_ctx.symbol_table[nnn]; !exists {
				disasm_ctx.symbol_table[nnn] = fmt.aprintf("label%d", label_counter)
				label_counter += 1
			}
		}
	}

	strings.write_string(&disasm_ctx.builder, "_start:\n")
	row := 1
	for i := 0; i < len(bytes); i += 2 {
		defer row += 1

		if i + 1 >= len(bytes) {
			break
		}

		if label, exists := disasm_ctx.symbol_table[disasm_ctx.org + i]; exists {
			fmt.sbprintfln(&disasm_ctx.builder, "%s:", label)
			row += 1
		}
		disasm_ctx.row_addrs[disasm_ctx.org + i] = row

		opcode := (u16(bytes[i]) << 8) | u16(bytes[i + 1])

		nibble := opcode >> 12
		x := (opcode >> 8) & 0x0F
		y := (opcode >> 4) & 0x0F
		nn := opcode & 0x00FF
		nnn := opcode & 0x0FFF

		switch nibble {
		case 0x0:
			switch nn {
			case 0xE0: strings.write_string(&disasm_ctx.builder, "    cls\n")
			case 0xEE: strings.write_string(&disasm_ctx.builder, "    ret\n")
			}
		case 0x1: fmt.sbprintfln(&disasm_ctx.builder, "    j %s", disasm_ctx.symbol_table[int(nnn)])
		case 0x2: fmt.sbprintfln(&disasm_ctx.builder, "    call %s", disasm_ctx.symbol_table[int(nnn)])
		case 0x3: fmt.sbprintfln(&disasm_ctx.builder, "    seqi v%X, %v", x, nn)
		case 0x4: fmt.sbprintfln(&disasm_ctx.builder, "    snei v%X, %v", x, nn)
		case 0x5: fmt.sbprintfln(&disasm_ctx.builder, "    seq v%X, v%X", x, y)
		case 0x6: fmt.sbprintfln(&disasm_ctx.builder, "    li v%X, %v", x, nn)
		case 0x7: fmt.sbprintfln(&disasm_ctx.builder, "    addi v%X, %v", x, nn)
		case 0x8:
			switch opcode & 0x000F {
			case 0x0: fmt.sbprintfln(&disasm_ctx.builder, "    mv v%X, v%X", x, y)
			case 0x1: fmt.sbprintfln(&disasm_ctx.builder, "    or v%X, v%X", x, y)
			case 0x2: fmt.sbprintfln(&disasm_ctx.builder, "    and v%X, v%X", x, y)
			case 0x3: fmt.sbprintfln(&disasm_ctx.builder, "    xor v%X, v%X", x, y)
			case 0x4: fmt.sbprintfln(&disasm_ctx.builder, "    add v%X, v%X", x, y)
			case 0x5: fmt.sbprintfln(&disasm_ctx.builder, "    sub v%X, v%X", x, y)
			case 0x6: fmt.sbprintfln(&disasm_ctx.builder, "    mv.sll v%X, v%X", x, y)
			case 0x7: fmt.sbprintfln(&disasm_ctx.builder, "    subn v%X, v%X", x, y)
			case 0xE: fmt.sbprintfln(&disasm_ctx.builder, "    mv.slr v%X, v%X", x, y)
			}
		case 0x9: fmt.sbprintfln(&disasm_ctx.builder, "    sne v%X, v%X", x, y)
		case 0xA: fmt.sbprintfln(&disasm_ctx.builder, "    la i, 0x%03X", nnn)
		case 0xB: fmt.sbprintfln(&disasm_ctx.builder, "    jdx %s, v0", disasm_ctx.symbol_table[int(nnn)])
		case 0xC: fmt.sbprintfln(&disasm_ctx.builder, "    rnd v%X, 0x%02X", x, nn)
		case 0xD: fmt.sbprintfln(&disasm_ctx.builder, "    draw v%X, v%X, 0x%X", x, y, opcode & 0x000F)
		case 0xE:
			switch nn {
			case 0x9E: fmt.sbprintfln(&disasm_ctx.builder, "    skey v%X", x)
			case 0xA1: fmt.sbprintfln(&disasm_ctx.builder, "    snkey v%X", x)
			}
		case 0xF:
			switch nn {
			case 0x07: fmt.sbprintfln(&disasm_ctx.builder, "    tm.r v%X, dt", x)
			case 0x0A: fmt.sbprintfln(&disasm_ctx.builder, "    wkey v%X", x)
			case 0x15: fmt.sbprintfln(&disasm_ctx.builder, "    tm.w dt, v%X", x)
			case 0x18: fmt.sbprintfln(&disasm_ctx.builder, "    tm.w st, v%X", x)
			case 0x1E: fmt.sbprintfln(&disasm_ctx.builder, "    add.p i, v%X", x)
			case 0x29: fmt.sbprintfln(&disasm_ctx.builder, "    la.font i, v%X", x)
			case 0x33: fmt.sbprintfln(&disasm_ctx.builder, "    sbcd (i), v%X", x)
			case 0x55: fmt.sbprintfln(&disasm_ctx.builder, "    sr (i), v0, v%X", x)
			case 0x65: fmt.sbprintfln(&disasm_ctx.builder, "    lr v0, v%X, (i)", x)
			}
		}
	}
	
	return strings.to_string(disasm_ctx.builder)
}

resolve :: proc(asm_ctx: ^Asm_Context) -> bool {
	current_global_label: string
	has_errors: bool

	for &stmt in asm_ctx.program {
		requires_section := false
		is_text := false
		is_data := false

		loc: Source_Location

		switch &s in stmt {
		case Label_Decl:
			requires_section = true
			loc = s.loc
		case Instruction_Decl:
			requires_section = true
			is_text = true
			loc = s.loc
		case Directive_Decl:
			#partial switch s.kind {
			case .Org:
				requires_section = true
			case .Byte, .Word, .Ascii:
				is_data = true
				requires_section = true
			}
			loc = s.loc
		}

		if requires_section && asm_ctx.current_section == .None {
			append(
				&asm_ctx.diagnostics,
				{
					code = .Sem_Missing_Section_Directive,
					loc = loc,
					message = fmt.aprintf("Statement defined outside of any active section"),
					label = "no active section found",
					hint = "Declare a section (like '.text' or '.data') before defining labels, code, or data",
				},
			)
			has_errors = true
			continue
		}

		if is_text && asm_ctx.current_section != .Text {
			append(
				&asm_ctx.diagnostics,
				{
					code = .Sem_Invalid_Section_Placement,
					loc = loc,
					message = "Instruction placed in non-executable section",
					label = "code execution not allowed in this section",
					hint = "Switch to the code section by adding the '.text' directive before instructions",
				},
			)
			has_errors = true
			continue
		}

		if is_data && asm_ctx.current_section != .Data {
			append(
				&asm_ctx.diagnostics,
				{
					code = .Sem_Invalid_Section_Placement,
					loc = loc,
					message = "Data directive placed in non-data section",
					label = "data definition not allowed here",
					hint = "Switch to the data section by adding the '.data' directive before defining data",
				},
			)
			has_errors = true
			continue
		}

		#partial switch &s in stmt {
		case Directive_Decl:
			directive := stmt.(Directive_Decl)

			#partial switch directive.kind {
			case .Org:
				if len(directive.args) > 0 {
					if val, is_imm := directive.args[0].(int); is_imm {
						current_pc := asm_ctx.section_pcs[asm_ctx.current_section]

						if val < current_pc {
							append(
								&asm_ctx.diagnostics,
								{
									code = .Sem_Invalid_Org_Offset,
									loc = directive.loc,
									message = fmt.aprintf(
										"Cannot move .org counter backward (from 0x%X to 0x%X)",
										current_pc,
										val,
									),
									label = "attempted to decrement location counter",
									hint = "The .org directive can only advance the address counter or leave it unchanged",
								},
							)
							has_errors = true
							continue
						}

						asm_ctx.section_pcs[asm_ctx.current_section] = val
					} else {
						has_errors = true
					}
				}
			case .Text:
				asm_ctx.current_section = .Text
			case .Data:
				asm_ctx.current_section = .Data
			case .Byte:
				asm_ctx.section_pcs[.Data] += len(directive.args)
			case .Word:
				asm_ctx.section_pcs[.Data] += len(directive.args) * 2
			case .Ascii:
				for arg in directive.args {
					if str, is_str := arg.(string); is_str {
						asm_ctx.section_pcs[.Data] += len(str)
					}
				}
			case .Invalid:
			}
		case Label_Decl:
			label := stmt.(Label_Decl)
			if label.is_local {
				if len(current_global_label) == 0 {
					append(
						&asm_ctx.diagnostics,
						{
							code = .Sem_Orphaned_Local_Label,
							loc = label.loc,
							message = "Local label declared before any global label",
							label = "orphaned local label",
							hint = "Define a global label (e.g., 'label:') before defining local labels",
						},
					)
					has_errors = true
					continue
				}
				label.resolved_name = fmt.aprintf("%s$%s", current_global_label, label.raw_name)
			} else {
				label.resolved_name = label.raw_name
				current_global_label = label.raw_name
			}

			if label.resolved_name in asm_ctx.symbol_table {
				append(
					&asm_ctx.diagnostics,
					{
						code = .Sem_Duplicate_Label_Definition,
						loc = label.loc,
						message = fmt.aprintf(
							"Duplicate definition of label '%s'",
							label.raw_name,
						),
						label = "redefinition of existing label",
						hint = "rename this label to avoid conflicts with previous definitions",
					},
				)
				has_errors = true
				continue
			}
			asm_ctx.symbol_table[label.resolved_name] = Symbol_Info {
				address = asm_ctx.section_pcs[asm_ctx.current_section],
				section = asm_ctx.current_section,
				loc     = label.loc,
			}
		case Instruction_Decl:
			instruction := &stmt.(Instruction_Decl)
			asm_ctx.section_pcs[.Text] += 2
		}
	}

	start_symbol, exists := asm_ctx.symbol_table["_start"]
	if !exists {
		append(
			&asm_ctx.diagnostics,
			{
				code = .Sem_Missing_Entry_Point,
				message = "Missing global entry point '_start'",
				label = "entry point symbol not found",
				hint = "define a global '_start:' label to serve as the application entry point",
			},
		)
		has_errors = true
	}
	return !has_errors
}

