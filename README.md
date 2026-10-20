<div align="center">  

  # Ch44 Toolchain

  **CHIP-8 Toolchain** — A set of development tools for 
  creating, debugging, and running CHIP-8 programs

</div>

## Features
- 👾 CHIP-8 Bytecode Interpreter (Register-Based Virtual Machine)
- ⚙️ Assembler
- 🔍 Assembly diagnostics report (clear error reporting and code analysis during assembly)
- 🪲 Disassembler
- 🚀 Super-CHIP extension 

> [!NOTE]
> Currently, the assembler and disassembler support the **standard CHIP-8 specification only**.

## Project Formats
The assembler uses a file format **`.ch44sm`** for source code. Ensure your source files
use this extension before assembly.

## Quick start
### Prerequisites
Before getting started, ensure you have the following tools installed:
* **[Git](https://git-scm.com/):** For cloning the repository.
* **[Odin Compiler](https://odin-lang.org/):** The project is written in Odin, so you will need
the compiler and its base, core and vendor packages which come pre-bundled with the compiler.
Follow the [Official Installation Guide](https://odin-lang.org/docs/install/).
* **[SDL3](https://libsdl.org/):** The Ch44 Toolchain relies on SDL3 for graphics, input and audio. 

### Installation & Running
#### 1. Clone the repository
First, clone the repository to your local machine and navigate into the project directory:

```bash
git clone https://github.com/wellman4/ch44tc.git
cd ch44tc
```

#### 2. Run the toolchain
Use the Odin compiler to build and run the project. For example, to run an assembly file:

```bash
odin run src -- run ./asm/main.ch44sm
```
