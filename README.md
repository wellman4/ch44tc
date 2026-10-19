<div align="center">  

  # Ch44tc

  **CHIP-8 Toolchain** — A set of development tools for 
  creating, debugging, and running CHIP-8 programs, written in Odin

</div>

## Features
- CHIP-8 Bytecode Interpreter (Register-Based Virtual Machine)
- Assembler
- Assembly diagnostics report (clear error reporting and code analysis during assembly)
- Disassembler
- Super-CHIP extension 

## Project Formats
The assembler uses a file format **`.ch44sm`** for source code. Ensure your source files
use this extension before assembly.

## Quick start
```bash
git clone https://github.com/wellman4/ch44tc.git
cd ch44tc
odin run src -- run ./asm/main.ch44sm
```
