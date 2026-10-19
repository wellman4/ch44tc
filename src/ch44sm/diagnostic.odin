package ch44sm

import "core:fmt"
import "core:strings"

COLOR_RESET   :: "\x1b[0m"
COLOR_BOLD    :: "\x1b[1m"
COLOR_RED     :: "\x1b[31m"
COLOR_GREEN   :: "\x1b[32m"
COLOR_BLUE    :: "\x1b[94m"
COLOR_CYAN    :: "\x1b[96m"
COLOR_MAGENTA :: "\u001b[35m"
COLOR_YELLOW  :: "\x1b[33m"
COLOR_ORANGE  :: "\x1b[38;5;208m"
COLOR_GRAY    :: "\u001b[90m"
COLOR_COMMENT :: "\x1b[90m"

Diagnostic :: struct {
	code: Diagnostic_Code,
	loc: Source_Location,
	message: string,
	label: string,
	hint: string,
}

Diagnostic_Code :: enum {
	// Lexical
	Lex_Invalid_Character,
	Lex_Unterminated_String,
	Lex_Invalid_Integer_Literal,
	// Syntax
	Syn_Unexpected_Token,
	Syn_Missing_Operand,
	Syn_Extra_Operands,
	Syn_Invalid_Directive,
	Syn_Invalid_Mnemonic,
	Syn_Invalid_Register,
	// Semantic
	Sem_Integer_Out_Of_Range,
	Sem_Orphaned_Local_Label,
	Sem_Undefined_Label,
	Sem_Invalid_Org_Offset,
	Sem_Invalid_Section_Placement,
	Sem_Duplicate_Label_Definition,
	Sem_Invalid_Operand_Type,
	Sem_Missing_Section_Directive,
	Sem_Missing_Entry_Point,
	// Warning
	Wrn_Unused_Label,
}

Source_Location :: struct {
	path: string,
	row: int,
	col: int,
	len: int,
}

Report_Format :: enum {Default, One_Line}

get_code_info :: proc(code: Diagnostic_Code) -> (is_error: bool, code_str: string) {
	#partial switch code {
	case .Lex_Invalid_Character:          return true, "Lx00"
	case .Lex_Unterminated_String:        return true, "Lx01"
	case .Lex_Invalid_Integer_Literal:    return true, "Lx02"
	case .Syn_Unexpected_Token:           return true, "Sy00"
	case .Syn_Missing_Operand:            return true, "Sy01"
	case .Syn_Invalid_Register:           return true, "Sy02"
	case .Syn_Invalid_Mnemonic:           return true, "Sy03"
	case .Syn_Extra_Operands:             return true, "Sy04"
	case .Syn_Invalid_Directive:          return true, "Sy05"
	case .Sem_Undefined_Label:            return true, "Se00"
	case .Sem_Duplicate_Label_Definition: return true, "Se01"
	case .Sem_Invalid_Operand_Type:       return true, "Se02"
	case .Sem_Integer_Out_Of_Range:       return true, "Se03"
	case .Sem_Orphaned_Local_Label:       return true, "Se04"
	case .Sem_Missing_Section_Directive:  return true, "Se05"
	case .Sem_Missing_Entry_Point:        return true, "Se06"
	case .Sem_Invalid_Section_Placement:  return true, "Se07"
	case .Sem_Invalid_Org_Offset:         return true, "Se08"
	case .Wrn_Unused_Label:               return true, "Wn00"
	case: return true, "Err00"
	}
}

report_diagnostics :: proc(
	diagnostics: []Diagnostic,
	src: string,
	format: Report_Format,
) {
	is_chronological_order := false

	switch len(diagnostics) {
	case 0: return
	case 1..=3: is_chronological_order = true
	}

	chronological_pointer := is_chronological_order ? "v" : "^"

	errors_count := 0
	warnings_count := 0
	
    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)
	
	lines := strings.split_lines(src, context.allocator)

	i := is_chronological_order ? 0 : len(diagnostics) - 1 
	step := is_chronological_order ? 1 : -1
    for _ in 0..<len(diagnostics) {
    	defer i += step

    	diag := &diagnostics[i]

        is_error, code_str := get_code_info(diag.code)
        if is_error {errors_count += 1} else {warnings_count += 1}
        has_loc := diag.loc != {}

		severity_color := is_error ? COLOR_RED : COLOR_YELLOW
		severity_text  := is_error ? "error" : "warning"

        if format == .One_Line {
        	fmt.eprintfln("%s%v%v%s%v|%v%s %v%s%v",
        		chronological_pointer,
        		COLOR_BOLD,
        		severity_color,
        		code_str,
        		COLOR_RESET,
        		COLOR_COMMENT,
        		has_loc ? fmt.tprintf(
        			"%s:%d:%d%v",
        			diag.loc.path,
        			diag.loc.row,
        			diag.loc.col,
        			COLOR_RESET,
        		) : "",
        		COLOR_BOLD,
        		diag.message,
        		COLOR_RESET
	        )
	        continue
        }

        // Header
        fmt.eprintfln("%v%v%s[%s]:%v %v%s%v", COLOR_BOLD,
        	severity_color, severity_text, code_str, COLOR_RESET, COLOR_BOLD,
        	diag.message, COLOR_RESET
        )

        line_num_str := fmt.tprintf("%d", diag.loc.row)
        padding := has_loc ? strings.repeat(" ", len(line_num_str), context.temp_allocator) : ""

        // Location
		if has_loc {
	        fmt.eprintfln("%v%s-->%s:%d:%d%v", COLOR_COMMENT,
	            padding, diag.loc.path, diag.loc.row, diag.loc.col,
	        	COLOR_RESET
	        )

	        strings.builder_reset(&builder)

	        underline_padding_size := 0
	        current_visual_col := 1

	        for r in lines[diag.loc.row - 1] {
	            if r == '\t' {
	                strings.write_string(&builder, "    ")
	                if current_visual_col < diag.loc.col {
	                    underline_padding_size += 4
	                }
	                current_visual_col += 1
	            } else {
	                strings.write_rune(&builder, r)
	                if current_visual_col < diag.loc.col {
	                    underline_padding_size += 1
	                }
	                current_visual_col += 1
	            }
	        }
	        clean_line := strings.to_string(builder)
    
	        fmt.eprintfln("%s%s |%s", padding, COLOR_COMMENT, COLOR_RESET)
	        fmt.eprintfln("%s%v%d|%s %s",
				chronological_pointer,
	        	COLOR_COMMENT,
	        	diag.loc.row,
	        	COLOR_RESET,
	        	clean_line
	        )

	        underline_padding := strings.repeat(" ", underline_padding_size, context.temp_allocator)
	        underline_width := max(diag.loc.len, 1)
	        underline_symbols := strings.repeat("^", underline_width, context.temp_allocator)

	        fmt.eprintfln("%s%v |%v %s%v%s %s%v", 
	            padding, COLOR_COMMENT, COLOR_RESET,
	            underline_padding, COLOR_RED, underline_symbols, diag.label, COLOR_RESET)

        
	        fmt.eprintfln("%s%v |%v", padding, COLOR_COMMENT, COLOR_RESET)
		}

        if len(diag.hint) != 0 {
            fmt.eprintfln("%s  %vhint: %s%v", padding, COLOR_GREEN, diag.hint, COLOR_RESET)
        }
        
        fmt.eprintln()
        free_all(context.temp_allocator)
    }

	is_failed := errors_count > 0 
	status_str := is_failed ? "failed" : "succeeded"

 	fmt.eprintf(
 		"Assembly %v%v%s%v with: ",
 		COLOR_BOLD,
 		is_failed ? COLOR_RED : COLOR_YELLOW, status_str,
 		COLOR_RESET
 	)
	if errors_count > 0 && warnings_count > 0 {
	    fmt.eprintfln("%v%v%d errors%v and %v%v%d warnings%v", 
	        COLOR_BOLD, COLOR_RED, errors_count, COLOR_RESET, 
	        COLOR_BOLD,COLOR_YELLOW, warnings_count, COLOR_RESET)
	} else if errors_count > 0 {
	    fmt.eprintfln("%v%v%d errors%v", COLOR_BOLD, COLOR_RED, errors_count, COLOR_RESET)
	} else if warnings_count > 0 {
	    fmt.eprintfln("%v%v%d warnings%v", COLOR_BOLD, COLOR_YELLOW, warnings_count, COLOR_RESET)
	}
}
