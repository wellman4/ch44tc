package ch44sm

import "core:strconv"
import "core:fmt"

is_alpha :: #force_inline proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_' || b == '.'
}

is_digit :: #force_inline proc(b: u8) -> bool {
    return b >= '0' && b <= '9'
}

Token :: struct {
    kind: Token_Kind,
    value: Value,
    raw_text: string,
    loc: Source_Location,
}

Token_Kind :: enum u8 {
    Eof,
    Invalid,
    Newline,
    Colon,
    Comma,
    Open_Paren,
    Close_Paren,
    Integer,
    String,
    Identifier,
}

Value :: union {int, string}

Lexer :: struct {
    asm_ctx: ^Asm_Context,
    src_path: string,
    src: string,
    pos: int,
    row: int,
    col: int,
}

lexer_init :: proc(l: ^Lexer, asm_ctx: ^Asm_Context) {
    l.asm_ctx = asm_ctx
	l.src_path = asm_ctx.src_path
	l.src = asm_ctx.src
	l.row = 1
	l.col = 1
}

next_token :: proc(l: ^Lexer) -> Token {
    skip_whitespace_and_comments(l)

    start_pos := l.pos
    start_col := l.col
    loc := Source_Location{
        path = l.src_path,
        row = l.row,
        col = start_col,
        len = 1,    
    }

    if start_pos >= len(l.src) {
        return Token{kind = .Eof, loc = loc}
    }

    b := l.src[l.pos]

    switch {
    case b == '\n':
        l.pos += 1
        l.row += 1
        l.col = 1
        raw_text := l.src[start_pos:l.pos]
        return Token{
            kind = .Newline,
            raw_text = raw_text,
            loc = loc,
        }
    case b == ':':
        l.pos += 1
        l.col += 1
        raw_text := l.src[start_pos:l.pos]
        return Token{
            kind = .Colon,
            raw_text = raw_text,
            loc = loc,
        }
    case b == ',':
        l.pos += 1
        l.col += 1
        raw_text := l.src[start_pos:l.pos]
        return Token{
            kind = .Comma,
            raw_text = raw_text,
            loc = loc,
        }
    case b == '(':
        l.pos += 1
        l.col += 1
        raw_text := l.src[start_pos:l.pos]
        return Token{
            kind = .Open_Paren,
            raw_text = raw_text,
            loc = loc,
        }
    case b == ')':
        l.pos += 1
        l.col += 1
        raw_text := l.src[start_pos:l.pos]
        return Token{
            kind = .Close_Paren,
            raw_text = raw_text,
            loc = loc,
        }
    // Integer
    case is_digit(b):
        for l.pos < len(l.src) && (is_alpha(l.src[l.pos]) || is_digit(l.src[l.pos])) {
            l.pos += 1
            l.col += 1
        }
        raw_text := l.src[start_pos:l.pos]
        loc.len = len(raw_text)

        value, ok := strconv.parse_int(raw_text)
        if !ok {
            append(&l.asm_ctx.diagnostics, {
                code    = .Lex_Invalid_Integer_Literal,
                loc     = loc,
                message = "Invalid integer literal",
                label   = "unable to parse this number",
                hint    = "run 'help tokens' for details",
            })

    	    return Token{kind = .Invalid, raw_text = raw_text, loc = loc}
    	}

        return Token{
            kind = .Integer,
            value = value,
            raw_text = raw_text,
            loc = loc,
        }
    // String
    case b == '"':
        l.pos += 1
        l.col += 1
        
        string_contents_start := l.pos
        
        // Finding close quote
        for l.pos < len(l.src) && l.src[l.pos] != '"' {
            if l.src[l.pos] == '\\' {
                l.col += 1
                l.pos += 1                

                if l.pos >= len(l.src) do break
                l.col += 1
                l.pos += 1
                continue
            }

            if l.src[l.pos] == '\n' {
                break
            } 

            l.col += 1
            l.pos += 1
        }
        
        raw_text := l.src[start_pos:l.pos+1]
        value := l.src[start_pos+1:l.pos]
        loc.len = len(raw_text)

        if l.pos >= len(l.src) || l.src[l.pos] != '"' {
            append(&l.asm_ctx.diagnostics, {
                code    = .Lex_Unterminated_String,
                loc     = loc,
                message = "Unterminated string literal",
                label   = "this string is missing \"",
                hint    = "strings in directives (like .ascii) must be closed on the same line with '\"'.",
            })

            return Token{kind = .Invalid, raw_text = raw_text, loc = loc}
        }
        
        l.pos += 1
        l.col += 1

        return Token{
            kind = .String,
            raw_text = raw_text,
            value = value,
            loc = loc,
        }
    // Identifier
    case is_alpha(b) || b == '_':
        for l.pos < len(l.src) && (is_alpha(l.src[l.pos]) || is_digit(l.src[l.pos]) || l.src[l.pos] == '_') {
            l.pos += 1
            l.col += 1
        }
        raw_text := l.src[start_pos:l.pos]
        loc.len = len(raw_text)

        return Token{
            kind = .Identifier,
            raw_text = raw_text,
            loc = loc,
        }
    case:
        l.pos += 1;
        l.col += 1
        raw_text := l.src[start_pos:l.pos]
        loc.len = len(raw_text)

        append(&l.asm_ctx.diagnostics, {
            code    = .Lex_Invalid_Character,
            loc     = loc,
            message = fmt.aprintf("Invalid character '%s'", raw_text),
            label   = "unexpected character here",
            hint    = "run 'help tokens' for details",
        })

        return Token{kind = .Invalid, raw_text = raw_text, loc = loc}
	}
}

skip_whitespace_and_comments :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        b := l.src[l.pos]
        if b == ' ' || b == '\t' || b == '\r' {
            l.pos += 1
            l.col += 1
        } else if b == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
            for l.pos < len(l.src) && l.src[l.pos] != '\n' {
                l.pos += 1
                l.col += 1
            }
        } else {
            break
        }
    }
}

