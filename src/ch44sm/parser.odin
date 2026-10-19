package ch44sm

import "core:fmt"
import "core:strconv"
import "core:strings"

Parser :: struct {
	asm_ctx: ^Asm_Context,
    lexer: ^Lexer,
    curr_tok: Token,
    next_tok: Token,
    has_parsing_errors: bool,
}

parser_init :: proc(p: ^Parser, asm_ctx: ^Asm_Context, lexer: ^Lexer) {
	p.asm_ctx = asm_ctx
	p.lexer = lexer
    p.curr_tok = next_token(p.lexer)
    p.next_tok = next_token(p.lexer)

    if p.asm_ctx.emit_tokens {
    	append(&p.asm_ctx.tokens, p.curr_tok, p.next_tok)
    }
}

parser_advance :: proc(p: ^Parser) {
    p.curr_tok = p.next_tok
    p.next_tok = next_token(p.lexer)

    if p.asm_ctx.emit_tokens {
    	append(&p.asm_ctx.tokens, p.next_tok)
    }
}

parse :: proc(p: ^Parser) -> bool {
	pl: for {
		#partial switch p.curr_tok.kind {
		case .Eof: break pl
		case .Newline: parser_advance(p)
		case .Invalid: parser_synchronize(p)
		case:
			if stmt, ok := parse_statement(p); ok {
				append(p.asm_ctx.program, stmt)
			} else {
				parser_synchronize(p)
			}
		}
		free_all(context.temp_allocator)
	}
	return !p.has_parsing_errors
}

parser_synchronize :: proc(p: ^Parser) {
	p.has_parsing_errors = true
	sl: for {
		#partial switch p.curr_tok.kind {
		case .Eof: break sl
		case .Newline:
			parser_advance(p)
			break sl
		}
		parser_advance(p)
	}
}

parse_statement :: proc(p: ^Parser) -> (stmt: Statement, ok: bool) {
	if p.curr_tok.kind == .Identifier {
		is_dot_prefix := strings.has_prefix(p.curr_tok.raw_text, ".")
		if p.next_tok.kind == .Colon {
			return parse_label_decl(p, is_local = is_dot_prefix)
		} else if is_dot_prefix {
			return parse_directive_decl(p)
		}
	}
	return parse_instruction_decl(p)
}

parse_label_decl :: proc(p: ^Parser, is_local: bool) -> (stmt: Statement, ok: bool) {
	label_name := p.curr_tok.raw_text

	parser_advance(p)
	if !parser_expect(p, .Colon) do return

	stmt = Label_Decl{raw_name = label_name, is_local = is_local, loc = p.curr_tok.loc}
	ok = true
	return
}

parse_directive_decl :: proc(p: ^Parser) -> (stmt: Statement, ok: bool) {
	kind := parse_directive_kind(p.curr_tok.raw_text)
	if kind == .Invalid {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Invalid_Directive,
            loc     = p.curr_tok.loc,
            message = "Unknown assembler directive",
            label   = "no such directive exists",
            hint    = "run 'help directives' for a list of available directives",
        })
	}	

	decl := Directive_Decl{
		kind = kind,
		args = make([dynamic]Operand),
		loc = p.curr_tok.loc,
	}
	parser_advance(p)

	ol: for {
        #partial switch p.curr_tok.kind {
        case .Newline, .Eof: break ol
        case .String: append(&decl.args, Operand(p.curr_tok.value.(string)))
        case .Integer: append(&decl.args, Operand(p.curr_tok.value.(int)))
        case:
	        append(&p.asm_ctx.diagnostics, {
	            code    = .Syn_Unexpected_Token,
	            loc     = p.curr_tok.loc,
	            message = "Expected string or integer literal",
	            label   = "expected a string or integer here",
	            hint    = "make sure the argument is a literal (e.g., 123 or \"hello\")",
	        })
            return decl, false
        }

        parser_advance(p)

        if p.curr_tok.kind == .Comma {
            parser_advance(p)
            
            if p.curr_tok.kind == .Newline || p.curr_tok.kind == .Eof {
		        append(&p.asm_ctx.diagnostics, {
		            code    = .Syn_Missing_Operand,
		            loc     = p.curr_tok.loc,
		            message = "Trailing comma is not allowed",
		            label   = "expected an operand after this comma",
		            hint    = "remove the trailing comma or provide the next argument",
		        })
                return decl, false
            }
        } else {
            if p.curr_tok.kind != .Newline && p.curr_tok.kind != .Eof {
		        append(&p.asm_ctx.diagnostics, {
		            code    = .Syn_Unexpected_Token,
		            loc     = p.curr_tok.loc,
		            message = "Expected ',' or end of line",
		            label   = "expected ',' separator here",
		            hint    = "multiple operands must be separated by a comma",
		        })
                return decl, false
            }
        }
    }
	
	return decl, true
}

parse_instruction_decl :: proc(p: ^Parser) -> (stmt: Statement, ok: bool) {
    if p.curr_tok.kind != .Identifier {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Unexpected_Token,
            loc     = p.curr_tok.loc,
            message = "Expected an instruction mnemonic",
            label   = "expected an instruction name here",
            hint    = "run 'help mnemonics' for details",
        })
        return
    }

    instruction := Instruction_Decl{loc = p.curr_tok.loc}
	instruction.kind = parse_instruction_kind(p.curr_tok.raw_text)

    switch instruction.kind {
    case .Ret, .Cls:
	    parser_advance(p)
        if !expect_end_of_line(p) do return
    case .Skey, .Snkey, .Wkey:
	    parser_advance(p)
        r, ok := expect_register(p, GPR_SET)
        if !ok do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r
	    instruction.op_count = 1
    case .Call, .J:
	    parser_advance(p)
        addr, ok := expect_addr(p)
        if !ok do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = addr
	    instruction.op_count = 1
    case .Mv, .Mv_Sll, .Mv_Srl, .Seq, .Sne, .Add, .Sub, .Subn, .Or, .And, .Xor: 
	    parser_advance(p)
        r1, ok1 := expect_register(p, GPR_SET)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return 

        r2, ok2 := expect_register(p, GPR_SET)
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.op_count = 2
	case .Add_P, .La_Font:
	    parser_advance(p)
        r1, ok1 := expect_register(p, {.I})
        if !ok1 do return

        if !parser_expect(p, .Comma) do return 

        r2, ok2 := expect_register(p, GPR_SET) 
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.op_count = 2
	case .Sbcd:
	    parser_advance(p)
        r1, ok1 := expect_register(p, {.I}, indirect = true) 
        if !ok1 do return

        if !parser_expect(p, .Comma) do return 

        r2, ok2 := expect_register(p, GPR_SET) 
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.op_count = 2
	case .Tm_R:
	    parser_advance(p)
        r1, ok1 := expect_register(p, GPR_SET)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return 

        r2, ok2 := expect_register(p, {.Dt}) 
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.op_count = 2
	case .Tm_W:
	    parser_advance(p)
        r1, ok1 := expect_register(p, {.Dt, .St}) 
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        r2, ok2 := expect_register(p, GPR_SET)
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.op_count = 2
    case .Li, .Rnd, .Seqi, .Snei, .Addi:
	    parser_advance(p)
        r, ok1 := expect_register(p, GPR_SET)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        imm, ok2 := expect_immediate(p, 0, (1 << 8))
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r
	    instruction.operands[1] = imm
	    instruction.op_count = 2
    case .Jdx:
	    parser_advance(p)
        addr, ok1 := expect_addr(p)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        r, ok2 := expect_register(p, {.V0})
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = addr
	    instruction.operands[1] = r
	    instruction.op_count = 2
    case .La:
	    parser_advance(p)
        r, ok1 := expect_register(p, {.I})
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        addr, ok2 := expect_addr(p)
        if !ok2 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r
	    instruction.operands[1] = addr
	    instruction.op_count = 2
    case .Sr:
	    parser_advance(p)
        r1, ok1 := expect_register(p, {.I}, indirect = true)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        r2, ok2 := expect_register(p, {.V0})
        if !ok2 do return

        if !parser_expect(p, .Comma) do return

        r3, ok3 := expect_register(p, GPR_SET)
        if !ok3 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.operands[2] = r3
	    instruction.op_count = 3
    case .Lr:
	    parser_advance(p)
        r1, ok1 := expect_register(p, {.V0})
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        r2, ok2 := expect_register(p, GPR_SET)
        if !ok2 do return

        if !parser_expect(p, .Comma) do return
        r3, ok3 := expect_register(p, {.I}, indirect = true)

        if !ok3 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.operands[2] = r3
	    instruction.op_count = 3
    case .Draw:
	    parser_advance(p)
        r1, ok1 := expect_register(p, GPR_SET)
        if !ok1 do return

        if !parser_expect(p, .Comma) do return

        r2, ok2 := expect_register(p, GPR_SET) 
        if !ok2 do return

        if !parser_expect(p, .Comma) do return

        imm, ok3 := expect_immediate(p, 0, (1 << 4)) 
        if !ok3 do return

        if !expect_end_of_line(p) do return

	    instruction.operands[0] = r1
	    instruction.operands[1] = r2
	    instruction.operands[2] = imm
	    instruction.op_count = 3
    case .Invalid:
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Invalid_Mnemonic,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Unknown instruction mnemonic '%s'", p.curr_tok.raw_text),
            label   = "if this was intended to be a label, add ':'",
            hint    = "make sure the mnemonic is correct or run 'help mnemonics' for a list of available instructions",
        })
        return
    }

    return instruction, true
}

parser_expect :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr_tok.kind == kind {
		parser_advance(p)
		return true
	} else {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Unexpected_Token,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Expected token of type '%v', but got '%v'", kind, p.curr_tok.kind),
            label   = fmt.aprintf("expected '%v' here", kind),
            hint    = "make sure the syntax follows the expected instruction or directive format",
        })
		return false
	}
}

expect_end_of_line :: proc(p: ^Parser) -> bool {
	if p.curr_tok.kind != .Newline && p.curr_tok.kind != .Eof {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Extra_Operands,
            loc     = p.curr_tok.loc,
			message = fmt.aprintf("Too many operands for this instruction, found '%v'", p.curr_tok.kind),
            label   = "extra operand(s) starting here",
            hint    = "remove these extra arguments or make sure to move the next instruction to a new line",
        })
		return false
	}
	if p.curr_tok.kind == .Newline {
		parser_advance(p)
	}
	return true
}

expect_register :: proc(
	p: ^Parser,
	expected_register: bit_set[Register] = nil,
	indirect := false,
) -> (op: Operand, ok: bool) {
	if indirect {
		if p.curr_tok.kind != .Open_Paren {
	        append(&p.asm_ctx.diagnostics, {
	            code    = .Syn_Unexpected_Token,
	            loc     = p.curr_tok.loc,
	            message = "Expected opening parenthesis for indirect addressing",
	            label   = "expected '(' here",
	            hint    = "indirect operands must be enclosed in parentheses, e.g., (i)",
	        })
			return
		}
		parser_advance(p)
	}
	
	if p.curr_tok.kind != .Identifier {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Unexpected_Token,
            loc     = p.curr_tok.loc,
            message = "Expected a register name",
            label   = "expected a register name here",
            hint    = "make sure you provided a valid register identifier",
        })
		return
	}

	r := parse_register(p.curr_tok.raw_text)
	if r == .Invalid {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Invalid_Register,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Unknown register '%s'", p.curr_tok.raw_text),
            label   = "invalid register name here",
            hint    = "registers are case-sensitive; check if it is written in uppercase or has a typo. Run 'help registers' for details",
        })
		return
	}

	if expected_register != nil && r not_in expected_register {
        append(&p.asm_ctx.diagnostics, {
            code    = .Sem_Invalid_Operand_Type,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Invalid register '%s' for this operand", p.curr_tok.raw_text),
            label   = "this register type is not allowed here",
            hint    = "refer to the instruction set documentation for allowed registers",
        })
		return
	}
	parser_advance(p)

	if indirect {
		if p.curr_tok.kind != .Close_Paren {
	        append(&p.asm_ctx.diagnostics, {
	            code    = .Syn_Unexpected_Token,
	            loc     = p.curr_tok.loc,
	            message = "Expected closing parenthesis for indirect addressing",
	            label   = "expected ')' here",
	            hint    = "close the parentheses after the register name, e.g., (i)",
	        })
			return
		}
		parser_advance(p)
	}

	return Operand(r), true
}

expect_immediate :: proc(p: ^Parser, min, max: int) -> (op: Operand, ok: bool) {
	if p.curr_tok.kind != .Integer {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Unexpected_Token,
            loc     = p.curr_tok.loc,
            message = "Expected an integer literal",
            label   = "expected immediate value here",
            hint    = "immediate values must be integer literals (e.g., 4 or 0x8)",
        })
		return
	}

	value := p.curr_tok.value.(int)

	if value < min || value >= max {
        append(&p.asm_ctx.diagnostics, {
            code    = .Sem_Integer_Out_Of_Range,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Integer literal '%d' is out of range [%d; %d]", value, min, max),
            label   = fmt.aprintf("value must fit within the range [%d; %d]", min, max),
            hint    = "Make sure the size matches (e.g., 8-bit or 12-bit). If you mixed up radix prefixes, note that '0b' is binary, '0o' is octal, and '0x' is hex",
        })
		return
	}

	parser_advance(p)
	return Operand(value), true
}


expect_addr :: proc(p: ^Parser) -> (op: Operand, ok: bool) {
	if p.curr_tok.kind == .Integer {
		return expect_immediate(p, min = 0, max = (1 << 12))
	}

	if p.curr_tok.kind == .Identifier {
		label_name := p.curr_tok.raw_text

		r := parse_register(label_name)
		if !(r == .Invalid) {
	        append(&p.asm_ctx.diagnostics, {
	            code    = .Sem_Invalid_Operand_Type,
	            loc     = p.curr_tok.loc,
	            message = fmt.aprintf("Expected address, but found register '%s'", label_name),
	            label   = "registers cannot be used as direct addresses",
	            hint    = "did you mean 'jdx addr, rs'? This instruction expects an address as its first argument, not a register",
			})
			return
		}

		label := Label{raw_name = label_name, loc = p.curr_tok.loc}
		parser_advance(p)
		return Operand(label), true
	} else {
        append(&p.asm_ctx.diagnostics, {
            code    = .Syn_Unexpected_Token,
            loc     = p.curr_tok.loc,
            message = fmt.aprintf("Expected address expression, found '%v'", p.curr_tok.kind),
            label   = "expected a label name or a immediate address here",
            hint    = "an address must be either an integer literal (e.g., 0x400) or a defined label identifier",
        })
		return
	}
}

parse_directive_kind :: proc(name: string) -> Directive_Kind {
	switch name {
	case ".org":         return .Org
	case ".byte", ".db": return .Byte
	case ".word", ".dw": return .Word
	case ".ascii":       return .Ascii
	case ".text":        return .Text
	case ".data":        return .Data
	case:                return .Invalid
	}
}

parse_instruction_kind :: proc(name: string) -> Instruction_Kind {
	switch name {
	case "mv":      return .Mv
	case "li":      return .Li
	case "add":     return .Add
	case "addi":    return .Addi
	case "sub":     return .Sub
	case "subn":    return .Subn
	case "or":      return .Or
	case "and":     return .And
	case "xor":     return .Xor
	case "mv.sll":  return .Mv_Sll
	case "mv.srl":  return .Mv_Srl
	case "rnd":     return .Rnd
	case "call":    return .Call
	case "ret":     return .Ret
	case "j":       return .J
	case "jdx":     return .Jdx
	case "seq":     return .Seq
	case "sne":     return .Sne
	case "seqi":    return .Seqi
	case "snei":    return .Snei
	case "skey":    return .Skey
	case "snkey":   return .Snkey
	case "cls":     return .Cls
	case "draw":    return .Draw
	case "wkey":    return .Wkey
	case "tm.r":    return .Tm_R
	case "tm.w":    return .Tm_W
	case "la":      return .La
	case "la.font": return .La_Font
	case "add.p":   return .Add_P
	case "sbcd":    return .Sbcd
	case "sr":      return .Sr
	case "lr":      return .Lr
	case:           return .Invalid
	}
}

parse_register :: proc(name: string) -> Register {
    switch name {
    case "v0", "a0":          return .V0
    case "v1", "a1":          return .V1
    case "v2", "a2":          return .V2
    case "v3", "a3":          return .V3
    case "v4", "s0":          return .V4
    case "v5", "s1":          return .V5
    case "v6", "s2":          return .V6
    case "v7", "s3":          return .V7
    case "v8", "s4":          return .V8
    case "v9", "t0":          return .V9
    case "v10", "va", "t1":   return .V10
    case "v11", "vb", "t2":   return .V11
    case "v12", "vc", "t3":   return .V12
    case "v13", "vd", "t4":   return .V13
    case "v14", "ve", "t5":   return .V14
    case "v15", "vf", "flag": return .V15
    case "i", "ptr":          return .I
    case "dt":                return .Dt
    case "st":                return .St
	case:                     return .Invalid
    }
}
