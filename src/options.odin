package main

import "core:flags"
import "core:fmt"
import "core:os"

import "vendor:sdl3"

import "ch44sm"
import "ch44vm"

Options :: union {
	Vm_Options,
	Asm_Options,
	Disasm_Options,
}

Vm_Options :: struct {
	src_path:   string                 `args:"pos=0,required" usage:"Path to the input file to execute. Can be either a compiled CHIP-8/Super-CHIP ROM bytecode or an assembly source file (.ch44sm)."`,
	target_fps: u16                    `usage:"Set the target main loop refresh rate in frames per second (e.g., 60)."`,
	volume:     f32                    `usage:"Set the audio volume level from 0.0 to 1.0."`,
	platform:   ch44vm.Platform        `usage:"Select a baseline hardware profile preset (Chip8, Super_Chip)."`,
	quirks:     ch44vm.Quirks          `usage:"A bitmask of quirks to modify the selected platform behavior. Acts as a TOGGLE (XOR)"`,
	tick_rate:  u16                    `usage:"Set the CPU speed in Hz (instructions per second)."`,
	colors:     [dynamic]u32           `args:"manifold=2" usage:"Set custom RGBA background and foreground colors for the display (e.g. 0x000000ff)."`,
	keys:       [dynamic]sdl3.Scancode `args:"manifold=16" usage:"Maps SDL3 scancodes to CHIP-8 keys using uppercase enum variants (e.g., X, _1, _2)."`,
	org:        u16                    `usage:"Memory address where the program is loaded"`,
	no_font:    bool                   `usage:"Skip loading the built-in font sprite data into the RAM."`,
	fullscreen: bool                   `usage:"Launch the virtual machine in fullscreen mode."`,
	maximized:  bool                   `usage:"Launch the virtual machine with a maximized window."`,
	mute:       bool                   `usage:"Mute all audio output (overrides --volume)."`,
	debug:      bool                   `usage:"Enable debug mode, press 'S' to step, press 'Tilde' to fullscreen VM display"`,
}

Asm_Options :: struct {
	src_path:      string               `args:"pos=0,required" usage:"Path to the source file (.ch44sm)."`,
	out_path:      string               `usage:"Specify the output path for the CHIP-8 bytecode."`,
	emit_tokens:   bool                 `usage:"Directs the parser to save tokens into an array."`,
	dump_tokens:   bool                 `usage:"Pretty-print the token array to the standard output (stdout)."`,
	dump_symbols:  bool                 `usage:"Pretty-print the assembler's symbol table to stdout."`,
	dump_ir:       bool                 `usage:"Pretty-print the Intermediate Representation (IR) to stdout."`,
	dump_bytecode: bool                 `usage:"Pretty-print the generated CHIP-8 bytecode instructions to stdout."`,
	dump_all:      bool                 `usage:"Pretty-print all assemble phases (tokens, symbols, IR, and bytecode)."`,
	report_format: ch44sm.Report_Format `usage:"Set the diagnostic error output style (Default, One_Line)."`,
	quiet:         bool                 `usage:"Disable all diagnostic printouts."`,
}

Disasm_Options :: struct {
	src_path: string `args:"pos=0,required" usage:"Path to the CHIP-8 bytecode source file (.ch8)"`,
	out_path: string `usage:"Specify the output path for the assembly program (.ch44sm)"`,
	org:      u16    `usage:"Base memory address (origin) where the binary is loaded."`,
}

options_init :: proc(opts: ^Options) -> (ok: bool) {
	if len(os.args) < 2 {
		print_global_help()
		return
	}

	command := os.args[1]
	parsing_style := flags.Parsing_Style.Unix
	err: flags.Error

	switch command {
	case "help", "-help", "--help", "-h":
		if len(os.args) > 2 {
			switch os.args[2] {
			case "tokens": fmt.print(tokens_help_message)
			case "directives": fmt.print(directives_help_message)
			case "mnemonics": fmt.print(mnemonics_help_message)
			case "registers": fmt.print(registers_help_message)
			case "quirks": fmt.print(quirks_help_message)
			case "help": fmt.print(help_help_message)
			case:
				fmt.eprintfln("Error: Unknown help subcommand '%s'. Run 'help' for global usage.", os.args[2])
			}
		} else {
			print_global_help()
		}
		return
	case "run":
		opts^ = Vm_Options {
			target_fps = 60,
			tick_rate  = 1400,
			volume     = 0.8,
			platform   = .Chip8,
			org        = 0x200,
		}
		vm_opts := (^Vm_Options)(opts)

		err = flags.parse(vm_opts, os.args[2:], parsing_style)
		if len(vm_opts.colors) > 0 && len(vm_opts.colors) != 2 {
			fmt.eprintfln("Error: expected 2 values for argument 'colors', got %d", len(vm_opts.colors))
			return
		}
		if len(vm_opts.keys) > 0 && len(vm_opts.keys) != 16 {
			fmt.eprintfln("Error: expected 16 values for argument 'keys', got %d", len(vm_opts.keys))
			return
		}
		if err != nil {
			handle_parse_error(err, Vm_Options, os.args[1], parsing_style)
			return
		}
	case "asm":
		opts^ = Asm_Options{}
		asm_opts := (^Asm_Options)(opts)
		err = flags.parse(asm_opts, os.args[2:], parsing_style)
		if err != nil {
			handle_parse_error(err, Asm_Options, os.args[1], parsing_style)
			return
		}
	case "disasm":
		opts^ = Disasm_Options{org=0x200}
		disasm_opts := (^Disasm_Options)(opts)
		err = flags.parse(disasm_opts, os.args[2:], parsing_style)
		if err != nil {
			handle_parse_error(err, Disasm_Options, os.args[1], parsing_style)
			return
		}
	case "version":
		fmt.printfln("%v v0.1.0", PROJECT_NAME)
		return
	case:
		print_global_help()
		return
	}

	return true
}

options_destroy :: proc(opts: ^Options) {
	#partial switch o in opts {
	case Vm_Options:
		delete(o.colors)
		delete(o.keys)
	}
}

handle_parse_error :: proc(
	err: flags.Error,
	opts_type: typeid,
	command: string,
	parsing_style: flags.Parsing_Style,
) {
	#partial switch e in err {
	case flags.Help_Request:
		flags.write_usage(os.to_stream(os.stdout), opts_type, command, parsing_style)
	case:
		flags.print_errors(opts_type, e, command, parsing_style)
	}
}

tokens_help_message := """
	Usage: help tokens

	Lexical structure & tokens:
	  - Source files must use UTF-8 encoding.
	  - Identifiers can contain letters (a-z, A-Z), digits (0-9), and underscores (_).
	  - Identifiers cannot start with a digit.

	Integer literal formats:
	  	Decimal:     90, -22
	  	Hexadecimal: 0x7F, 0XFF
	  	Binary:      0b1010, 0B1100
	  	Octal:       0o755

	String literals:
	  - Enclosed in double quotes (e.g., "Hello, World!").

	"""

directives_help_message := """
	Usage: help directives

	Available assembler directives:
	  .byte / .db   - Define 8-bit byte(s)
	  .word / .dw   - Define 16-bit word(s)
	  .ascii        - Define string encoded in ascii
	  .org          - Set the starting memory address (origin)
	  .text         - Define a text section
	  .data         - Define a data section

	"""

mnemonics_help_message := """
	Usage: help mnemonics

	Available assembler instruction mnemonics:
	  Data Transfer:
		[8xy0] mv rd, rs
		[6xnn] li rd, imm8

	  Arithmetic:
		[8xy4] add rs1, rs2
		[7xnn] addi rs1, imm8 
		[8xy5] sub rs1, rs2
		[8xy7] subn rs1, rs2

	  Logical:
		[8xy1] or rs1, rs2
		[8xy2] and rs1, rs2
		[8xy3] xor rs1, rs2
		[8xyE] mv.sll rd, rs
		[8xy6] mv.srl rd, rs
		[Cxnn] rnd rd, imm8

	  Control flow:
		[2nnn] call imm12
		[00EE] ret
		[1nnn] j imm12
		[Bnnn] jdx imm12, rs (rs == v0)
		[5xy0] seq rs1, rs2
		[9xy0] sne rs1, rs2
		[3xnn] seqi rs1, imm8
		[4xnn] snei rs1, imm8
		[Ex9E] skey rs
		[ExA1] snkey rs

	  System:
		[00E0] cls
		[Dxyn] draw rs1, rs2, imm4
		[Fx0A] wkey rd
		[Fx07] tm.r rd, dt
		[Fx15] tm.w dt, rs
		[Fx18] tm.w st, rs

	  Memory:
		[Annn] la i, imm12
		[Fx29] la.font i, rs
		[Fx1E] add.p i, rs
		[Fx33] sbcd (i), rs
		[Fx55] sr (i), rs1, rs2 (rs1 == v0) 
		[Fx65] lr rs1, rs2, (i) (rs1 == v0)

	"""

registers_help_message := """
	Usage: help registers

	Available CPU registers:

	General purpose:
		-----|-------|------------------
		Name | Alias | Description
		-----|-------|------------------
		v0   | a0    | Argument / Return
		v1   | a1    | Argument
		v2   | a2    | Argument
		v3   | a3    | Argument
		-----|-------|------------------
		v4   | s0    | Saved
		v5   | s1    | Saved
		v6   | s2    | Saved
		v7   | s3    | Saved
		v8   | s4    | Saved
		-----|-------|------------------
		v9   | t0    | Temporary
		v10  | t1    | Temporary
		v11  | t2    | Temporary
		v12  | t3    | Temporary
		v13  | t4    | Temporary
		v14  | t5    | Temporary
		-----|-------|------------------
		v15  | flag  | Flag

	Special registers:
		dt
		st

	Address register:
		i (alias ptr)
	
	"""

quirks_help_message := """
	Usage: help quirks

	Interpretation quirks(compatibility flags):
	Different CHIP-8, Super-CHIP, and XO-CHIP interpreters handle certain 
	instructions differently. Use these flags to toggle specific behaviors:

	Quirk :: enum {
		Vf_Reset,          // FX55/FX65 clear the VF register after execution (original behavior)
		Memory_Increment,  // FX55/FX65 increment the I register by X + 1 (original behavior)
		Vblank_Sync,       // DXYN (Display) waits for the vertical blanking interval (60Hz)
		Clipping,          // Sprites wrap around the screen edges instead of being clipped
		Shift,             // 8XY6/8XYE shift VX directly instead of copying VY to VX first
		Jump_With_Offset,  // BNNN jumps to NNN + VX instead of NNN + V0 (Super-CHIP behavior)
	}

	Quirks :: bit_set[Quirk]

	"""

help_help_message := """
	Usage: help help

	Available help subcommands:
		tokens:     Lexical structure, identifier rules, and literals
		directives: Compiler directives for data definition and sections
		mnemonics:  CPU instruction set mnemonics
		registers:  Available general and special purpose CPU registers
		quirks:     Interpreter compatibility flags for different CHIP-8 variants

	"""
