package main

import "base:runtime"
import "core:c"
import "core:flags"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:mem"
import "core:os"
import "core:strings"

import "vendor:sdl3"

import "ch44sm"
import "ch44vm"

PROJECT_NAME :: "ch44tc"

main :: proc() {
	opts := new(Options)
	defer free(opts)

	if !options_init(opts) do return

	arena: virtual.Arena
	arena_err := virtual.arena_init_growing(&arena)
	if arena_err != nil {
		fmt.eprintln("Cannot initialize arena")
		return
	}
	defer virtual.arena_destroy(&arena)

	translation_allocator := virtual.arena_allocator(&arena)

	switch o in opts {
	case Asm_Options:
		asm_ctx: ch44sm.Asm_Context
		run_asm_app(opts, &asm_ctx, translation_allocator)
	case Disasm_Options:
		disasm_ctx: ch44sm.Disasm_Context
		run_disasm_app(opts, &disasm_ctx, translation_allocator)
	case Vm_Options:
		run_vm_app(opts, translation_allocator)
	}
	free_all(context.temp_allocator)
}

print_global_help :: proc() {
	fmt.printfln("%v v0.1.0", PROJECT_NAME)
	fmt.printfln("\nUsage:")
	fmt.printfln("  %v <command> [arguments]", PROJECT_NAME)
	fmt.printfln("\nCommands:")
	fmt.printfln("  %-12s %s", "run", "Run the CHIP-8/Super-CHIP virtual machine")
	fmt.printfln("  %-12s %s", "asm", "Assemble .ch44sm source file into CHIP-8 bytecode")
	fmt.printfln("  %-12s %s", "disasm", "Disassemble CHIP-8 bytecode back into .ch44sm source code")
	fmt.printfln("  %-12s %s", "version", "Show project version information")
	fmt.printfln("  %-12s %s", "help", "Show this help window or help for a specific topic (e.g., 'help help')")
	fmt.printfln("\nUse '%v <command> --help' to see flags for a specific command.", PROJECT_NAME)
}

run_asm_app :: proc(
	opts: ^Options,
	asm_ctx: ^ch44sm.Asm_Context,
	allocator: mem.Allocator
) -> (ok: bool) {

	context.allocator = allocator
	opts := (^Asm_Options)(opts)

	src, err := os.read_entire_file_from_path(opts.src_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Error: failed to read source file at '%s'. Reason: %v", opts.src_path, err)
		return
	}

	ch44sm.asm_ctx_init(
		asm_ctx = asm_ctx,
		src_path = opts.src_path,
		src = string(src),
		emit_tokens = opts.emit_tokens,
		allocator = allocator,
	)

	if opts.dump_tokens || opts.dump_all do asm_ctx.emit_tokens = true

	asm_ok := ch44sm.assemble(asm_ctx, context.allocator)
	if (opts.dump_tokens || opts.dump_all) && asm_ctx.emit_tokens {
		dump_tokens(asm_ctx)
	}
	if (opts.dump_ir || opts.dump_all) && len(asm_ctx.program) != 0 {
		dump_ir(asm_ctx)
	}
	if (opts.dump_symbols || opts.dump_all) && len(asm_ctx.symbol_table) != 0 {
		dump_symbols(asm_ctx)
	}
	if (opts.dump_bytecode || opts.dump_all) && len(asm_ctx.bytecode) != 0 {
		dump_bytecode(asm_ctx)
	}

	if asm_ok {
		if len(opts.out_path) > 0 {
			write_err := os.write_entire_file(opts.out_path, asm_ctx.bytecode[:])
			if write_err != nil {
				fmt.eprintfln("Error: failed to write output file at '%s'. Reason: %v", opts.out_path, write_err)
				return
			}
		}
	} else if !opts.quiet {
		ch44sm.report_diagnostics(asm_ctx.diagnostics[:], asm_ctx.src, opts.report_format)
		return
	}

	return true
}

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

run_disasm_app :: proc(
	opts: ^Options,
	disasm_ctx: ^ch44sm.Disasm_Context,
	allocator: mem.Allocator
) -> (ok: bool) {

	context.allocator = allocator
	opts := (^Asm_Options)(opts)

	bytecode, err := os.read_entire_file_from_path(opts.src_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Error: failed to read source file at '%s'. Reason: %v", opts.src_path, err)
		return
	}

	ch44sm.disasm_ctx_init(
		disasm_ctx = disasm_ctx,
		src_path = opts.src_path,
		src = bytecode,
		allocator = allocator
	)
	
	if len(opts.out_path) > 0 {
		write_err := os.write_entire_file(opts.out_path, ch44sm.disassemble(disasm_ctx, context.allocator))
		if write_err != nil {
			fmt.eprintfln("Error: failed to write output file at '%s'. Reason: %v", opts.out_path, err)
			return
		}
	}
	return true
}
