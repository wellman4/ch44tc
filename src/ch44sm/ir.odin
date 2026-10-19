package ch44sm

Program :: distinct [dynamic]Statement

Statement :: union {
    Directive_Decl,
    Label_Decl,
    Instruction_Decl,
}

Directive_Decl :: struct {
    kind: Directive_Kind,
    args: [dynamic]Operand,
    loc: Source_Location,
}

Directive_Kind :: enum {
    Org, Text, Data,
    Byte, Word, Ascii,
    Invalid,
}

Label_Decl :: struct {
    raw_name: string,
    resolved_name: string,
    is_local: bool,
    loc: Source_Location,
}

Instruction_Decl :: struct {
    kind: Instruction_Kind,
    operands: [3]Operand,
    op_count: u8,
    loc: Source_Location,
}

Instruction_Kind :: enum {
    Mv, Li,
    Add, Addi, Sub, Subn,
    Or, And, Xor, Mv_Sll, Mv_Srl, Rnd,
    Call, Ret, J, Jdx, Seq, Sne, Seqi, Snei, Skey, Snkey,
    Cls, Draw, Wkey, Tm_R, Tm_W,
    La, La_Font, Add_P, Sbcd, Sr, Lr,
    Invalid,
}

Operand :: union {
    Register,
    Label,
    int,
    string,
}

Register :: enum {
    V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15,
    Dt, St, I,
    Invalid,
}

Label :: struct {
    raw_name: string,
    resolved_address: u16,
    loc: Source_Location,
}

GPR_SET :: bit_set[Register]{
    .V0, .V1, .V2, .V3, .V4, .V5, .V6, .V7,
    .V8, .V9, .V10, .V11, .V12, .V13, .V14, .V15
}
SPECIAL_SET :: bit_set[Register]{.Dt, .St}
ANY_REG_SET :: GPR_SET + SPECIAL_SET + bit_set[Register]{.I}
