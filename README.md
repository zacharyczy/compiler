# NJU Compiler Principles Labs

南京大学（NJU）编译原理课程实验的个人实现。项目使用 C、Flex 和 Bison，按实验阶段逐步完成一个面向 C--/CMM 风格输入语言的编译器。

> 本仓库仅用于个人学习、复习与代码归档，不是课程官方实现。请遵守课程的学术诚信要求，不要直接复制代码作为作业提交。

## 实验内容

| 目录 | 内容 | 程序输入与输出 |
| --- | --- | --- |
| `lab1` | 词法分析、语法分析与抽象语法树（AST） | `.cmm` 源文件 → AST/错误信息 |
| `lab2` | 符号表、类型系统与语义检查 | `.cmm` 源文件 → 语义检查结果 |
| `lab3` | 中间代码（IR）生成 | `.cmm` 源文件 → `.ir` 文件 |
| `lab4` | MIPS32 目标代码生成 | `.cmm` 源文件 → `.s` 汇编文件 |
| `lab5` | 基于控制流图的数据流分析与中间代码优化 | `.ir` 文件 → 优化后的 `.ir` 文件 |

## 环境依赖

建议在 Linux 或 WSL 环境中构建，所需工具如下：

- GCC（支持 C99）
- GNU Make
- Flex
- Bison

以 Ubuntu/Debian 为例：

```bash
sudo apt update
sudo apt install build-essential flex bison
```

## 构建

每个 Lab 都可以独立构建。例如：

```bash
cd lab1
make
```

构建生成的可执行文件名为 `parser`。清理构建产物：

```bash
make clean
```

## 运行

Lab 1（打印抽象语法树）：

```bash
./parser input.cmm
```

Lab 2（执行语义检查）：

```bash
./parser input.cmm
```

Lab 3（生成中间代码）：

```bash
./parser input.cmm output.ir
```

Lab 4（生成 MIPS32 汇编）：

```bash
./parser input.cmm output.s
```

Lab 5（优化中间代码）：

```bash
./parser input.ir output.ir
```

## 项目结构

每个实验目录主要包含：

- `lexical.l`：Flex 词法规则
- `syntax.y`：Bison 语法规则，以及相应阶段的 AST、语义分析或中间代码生成逻辑
- `main.c`：命令行入口
- `Makefile`：构建脚本
- `mips.c` / `mips.h`：MIPS32 代码生成（Lab 4、Lab 5）
- `optimizer.c` / `optimizer.h`：中间代码优化（Lab 5）

## 说明

- 各 Lab 是按课程进度保存的独立版本，因此前一阶段的部分代码会在后续目录中重复出现。
- `Makefile` 使用了 `find`、`sed` 等 Unix 工具，原生 Windows PowerShell 环境下建议通过 WSL 构建。
- 仓库没有包含课程测试数据；运行时请自行准备符合实验语法的 `.cmm` 或 `.ir` 输入文件。

