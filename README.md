<div align="center">
  
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/ch44tc_logo_dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/ch44tc_logo_light.svg">
    <img alt="Ch44 Toolchain Logo" src="assets/ch44tc_logo_light.svg" width="300">
  </picture>

  # Ch44 Toolchain

  **CHIP-8 Toolchain** — A set of development tools for 
  creating, debugging, and running CHIP-8 programs

</div>

## ✨ Features
- 🪲 Debugger
- 👾 CHIP-8 Bytecode Interpreter (Register-Based Virtual Machine)
- ⚙️ Assembler
- 🔍 Assembly diagnostics report (clear error reporting and code analysis during assembly)
- 🔓 Disassembler
- 🚀 Super-CHIP extension 

> [!NOTE]
> Currently, the assembler and disassembler support the **standard CHIP-8 specification only**.
The disassembler may generate *junk instructions*

## 💾 Project Formats
The assembler uses a file format **`.ch44sm`** for source code. Ensure your source files
use this extension before assembly.

## 🏁 Quick start
### Prerequisites
Before getting started, ensure you have the following tools installed:
* **[Git](https://git-scm.com/):** For cloning the repository.
* **[Odin](https://odin-lang.org/):** The project is written in Odin, so you will need
the compiler and its base, core and vendor packages which come pre-bundled with the compiler.
Follow the [Official Installation Guide](https://odin-lang.org/docs/install/).
* **[SDL3](https://libsdl.org/):** The Ch44 Toolchain relies on SDL3 for graphics, input and audio, and uses the SDL3_ttf for font rendering.

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

## 💖 Support the Project
If you find this project useful or interesting, you can support its development by:
* 🌟 **Leaving a star** on GitHub to help others discover it.

Your support means a lot and keeps the project moving forward!

## 👤 Author
**wellman4**

## ⚖️ Trademark & Brand Guidelines

The source code of this project is licensed under the [Apache-2.0 license](LICENSE). However, the project name **"Ch44 Toolchain"** and its official **logos** (including all SVG assets) are subject to the following restrictions:

* **Naming of Derivative Works:** You **cannot** use the name "Ch44 Toolchain", "Ch44TC", confusingly similar names, derivatives, or the official project logos in the name, branding, or marketing of any derivative projects, forks, or commercial products.
* **References & Attribution:** You **are permitted and encouraged** to use the project name and logos exclusively for the purpose of linking back to this original repository or referencing it as an upstream source.

For any questions regarding branding or permission requests, please open an Issue in this repository.