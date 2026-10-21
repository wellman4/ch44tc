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

	asm_ctx.src_path     = opts.src_path
	asm_ctx.src          = string(src)
	asm_ctx.emit_tokens  = opts.emit_tokens
	asm_ctx.diagnostics  = make([dynamic]ch44sm.Diagnostic)
	asm_ctx.tokens       = make([dynamic]ch44sm.Token)
	asm_ctx.program      = new(ch44sm.Program)
	asm_ctx.symbol_table = make(map[string]ch44sm.Symbol_Info)
	asm_ctx.bytecode     = make([dynamic]u8)

	asm_ok := ch44sm.assemble(asm_ctx, context.allocator)

	if opts.dump_tokens || opts.dump_all do asm_ctx.emit_tokens = true
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

run_disasm_app :: proc(
	opts: ^Options,
	disasm_ctx: ^ch44sm.Disasm_Context,
	allocator: mem.Allocator
) -> (ok: bool) {

	context.allocator = allocator
	opts := (^Disasm_Options)(opts)

	bytecode, err := os.read_entire_file_from_path(opts.src_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Error: failed to read source file at '%s'. Reason: %v", opts.src_path, err)
		return
	}

	disasm_ctx.src_path     = opts.src_path
	disasm_ctx.src          = bytecode
	disasm_ctx.org          = opts.org
	disasm_ctx.symbol_table = make(map[int]string, context.allocator)
	strings.builder_init(&disasm_ctx.builder, context.allocator)
	
	if len(opts.out_path) > 0 {
		write_err := os.write_entire_file(opts.out_path, ch44sm.disassemble(disasm_ctx, context.allocator))
		if write_err != nil {
			fmt.eprintfln("Error: failed to write output file at '%s'. Reason: %v", opts.out_path, err)
			return
		}
	}
	return true
}
