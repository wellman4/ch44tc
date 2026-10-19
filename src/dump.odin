package main

import "core:fmt"
import "core:strings"

import "ch44sm"

dump_tokens :: proc(asm_ctx: ^ch44sm.Asm_Context) {
	fmt.printfln("%v%v%s Tokens%v",
		ch44sm.COLOR_BOLD,
		ch44sm.COLOR_RED,
		fmt.tprintf(strings.repeat("-", 70, context.temp_allocator)),
		ch44sm.COLOR_RESET,
	)
	for &t in asm_ctx.tokens {
		fmt.printfln(
			"%-40s%v|%v%-27s%v|%v%v%v",
			fmt.tprintf(
				"%v%s/%d:%d",
				ch44sm.COLOR_COMMENT,
				t.loc.path,
				t.loc.row,
				t.loc.col,
			),
			ch44sm.COLOR_RESET,
			ch44sm.COLOR_GREEN,
			fmt.tprintf("%q", t.raw_text),
			ch44sm.COLOR_RESET,
			ch44sm.COLOR_BLUE,
			t.kind,
			ch44sm.COLOR_RESET,
		)
	}
}

dump_ir :: proc(asm_ctx: ^ch44sm.Asm_Context) {
	fmt.printfln(
		"%v%v%s IR (parsed program)%v",
		ch44sm.COLOR_BOLD,
		ch44sm.COLOR_RED,
		fmt.tprintf(strings.repeat("-", 70, context.temp_allocator)),
		ch44sm.COLOR_RESET,
	)

	for &stmt, i in asm_ctx.program {
		fmt.printf("%s[Statement %d]%s ", ch44sm.COLOR_GRAY, i, ch44sm.COLOR_RESET)

		switch &s in stmt {
		case ch44sm.Directive_Decl:
			fmt.printfln(
				"%vDirective_Decl%v (.%v) %sat %d:%d%s",
				ch44sm.COLOR_BOLD,
				ch44sm.COLOR_RESET,
				s.kind,
				ch44sm.COLOR_GRAY,
				s.loc.row,
				s.loc.col,
				ch44sm.COLOR_RESET,
			)
			for &arg, idx in s.args {
				fmt.printf(
					"  %v├── arg[%d]:%v ",
					ch44sm.COLOR_GRAY,
					idx,
					ch44sm.COLOR_RESET,
				)
				print_operand_colored(arg)
				fmt.println()
			}

		case ch44sm.Label_Decl:
			type_str := "global" if !s.is_local else "local"
			color := ch44sm.COLOR_GREEN if !s.is_local else ch44sm.COLOR_CYAN
			fmt.printfln(
				"%sLabel_Decl%s (%s%s%s%v) %sat %d:%d%s",
				ch44sm.COLOR_BOLD,
				ch44sm.COLOR_RESET,
				ch44sm.COLOR_BOLD,
				color,
				type_str,
				ch44sm.COLOR_RESET,
				ch44sm.COLOR_GRAY,
				s.loc.row,
				s.loc.col,
				ch44sm.COLOR_RESET,
			)
			fmt.printfln(
				"  %s├── raw_name:%v %q",
				ch44sm.COLOR_GRAY,
				ch44sm.COLOR_RESET,
				s.raw_name,
			)

		case ch44sm.Instruction_Decl:
			fmt.printfln(
				"%vInstruction_Decl%v (%v%v%s%v) %sat %d:%d%v",
				ch44sm.COLOR_BOLD,
				ch44sm.COLOR_RESET,
				ch44sm.COLOR_BOLD,
				ch44sm.COLOR_MAGENTA,
				s.kind,
				ch44sm.COLOR_RESET,
				ch44sm.COLOR_GRAY,
				s.loc.row,
				s.loc.col,
				ch44sm.COLOR_RESET,
			)
			for idx in 0 ..< s.op_count {
				fmt.printf(
					"  %s├── op[%d]:%v ",
					ch44sm.COLOR_GRAY,
					idx,
					ch44sm.COLOR_RESET,
				)
				print_operand_colored(s.operands[idx])
				fmt.println()
			}
		}
	}
}

dump_symbols :: proc(asm_ctx: ^ch44sm.Asm_Context) {
	fmt.printfln(
		"%v%v%s Symbol Table%v",
		ch44sm.COLOR_BOLD,
		ch44sm.COLOR_RED,
		fmt.tprintf(strings.repeat("-", 70, context.temp_allocator)),
		ch44sm.COLOR_RESET,
	)
	fmt.printfln(
		"%s%-30s|%-10s|%-12s%v",
		ch44sm.COLOR_BOLD,
		"Symbol name",
		"Section",
		"Address (hex)",
		ch44sm.COLOR_RESET,
	)
	fmt.printfln(
		"%v%v%s%v",
		ch44sm.COLOR_BOLD,
		ch44sm.COLOR_RED,
		fmt.tprintf(strings.repeat("-", 70, context.temp_allocator)),
		ch44sm.COLOR_RESET,
	)

	for name, info in asm_ctx.symbol_table {
		sec_color := info.section == .Text ? ch44sm.COLOR_GREEN : ch44sm.COLOR_ORANGE

		fmt.printfln(
			"%v%-30s%v|%s.%-9v%s|%s0x%03X%s",
			sec_color,
			name,
			ch44sm.COLOR_RESET,
			sec_color,
			info.section,
			ch44sm.COLOR_RESET,
			ch44sm.COLOR_BLUE,
			info.address,
			ch44sm.COLOR_RESET,
		)
	}
}

dump_bytecode :: proc(asm_ctx: ^ch44sm.Asm_Context) {
	fmt.printfln(
		"%v%v%s Bytecode%v",
		ch44sm.COLOR_BOLD,
		ch44sm.COLOR_RED,
		fmt.tprintf(strings.repeat("-", 70, context.temp_allocator)),
		ch44sm.COLOR_RESET,
	)

	for i := 0; i < len(asm_ctx.bytecode); i += 16 {
		fmt.printf("%s%08X:%s ", ch44sm.COLOR_GRAY, i, ch44sm.COLOR_RESET)

		for j := 0; j < 16; j += 1 {
			if i + j < len(asm_ctx.bytecode) {
				b := asm_ctx.bytecode[i + j]
				if b == 0 {
					fmt.printf("%s00%s ", ch44sm.COLOR_GRAY, ch44sm.COLOR_RESET)
				} else {
					fmt.printf("%02X ", b)
				}
			} else {
				fmt.printf("   ")
			}
		}

		fmt.printf("%s|%s", ch44sm.COLOR_GRAY, ch44sm.COLOR_RESET)

		for j := 0; j < 16; j += 1 {
			if i + j < len(asm_ctx.bytecode) {
				b := asm_ctx.bytecode[i + j]
				if b >= 32 && b <= 126 {
					fmt.printf("%s%c%s", ch44sm.COLOR_GREEN, b, ch44sm.COLOR_RESET)
				} else {
					fmt.printf("%s.%s", ch44sm.COLOR_GRAY, ch44sm.COLOR_RESET)
				}
			}
		}
		fmt.printfln("%s|%s", ch44sm.COLOR_GRAY, ch44sm.COLOR_RESET)
	}
}

print_operand_colored :: proc(op: ch44sm.Operand) {
	switch v in op {
	case ch44sm.Register:
		fmt.printf("%vRegister(%v)%v", ch44sm.COLOR_MAGENTA, v, ch44sm.COLOR_RESET)
	case ch44sm.Label:
		fmt.printf(
			"%vLabel(raw: %q, address: %X)%v",
			ch44sm.COLOR_BLUE,
			v.raw_name,
			v.resolved_address,
			ch44sm.COLOR_RESET,
		)
	case int:
		fmt.printf("%vInt(%d)%v", ch44sm.COLOR_YELLOW, v, ch44sm.COLOR_RESET)
	case string:
		fmt.printf("%vString(%q)%v", ch44sm.COLOR_GREEN, v, ch44sm.COLOR_RESET)
	case nil:
		fmt.printf("%vNone%v", ch44sm.COLOR_GRAY, ch44sm.COLOR_RESET)
	}
}
