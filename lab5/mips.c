#include "mips.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ========================= Lab 4: MIPS32 target code generation ========================= */

#define CG_MAX_INST 50000
#define CG_MAX_FUNCS 128
#define CG_MAX_VARS 4096
#define CG_MAX_PARAMS 128
#define CG_MAX_ARGS 128

typedef enum {
    CG_IR_NONE, CG_IR_FUNCTION, CG_IR_PARAM, CG_IR_LABEL, CG_IR_DEC,
    CG_IR_ASSIGN, CG_IR_BINOP, CG_IR_ADDR, CG_IR_LOAD, CG_IR_STORE,
    CG_IR_GOTO, CG_IR_IF, CG_IR_RETURN, CG_IR_ARG, CG_IR_CALL,
    CG_IR_READ, CG_IR_WRITE
} CGIRKind;

typedef struct {
    CGIRKind kind;
    char result[64];
    char op1[64];
    char op2[64];
    char op[8];
    char label[64];
    char func[64];
    int size;
    char text[256];
} CGIR;

typedef struct {
    char name[64];
    int offset;
    int size;
} CGVar;

typedef struct {
    char name[64];
    int start;
    int end;
    int param_count;
    char params[CG_MAX_PARAMS][64];
    int var_count;
    CGVar vars[CG_MAX_VARS];
    int frame_size;
} CGFunc;

static void cg_trim(char *s) {
    int n = (int)strlen(s);
    int i = 0;
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) {
        s[--n] = '\0';
    }
    while (s[i] == ' ' || s[i] == '\t') ++i;
    if (i > 0) memmove(s, s + i, strlen(s + i) + 1);
}

static int cg_is_const(const char *op) {
    return op && op[0] == '#';
}

static int cg_is_symbol(const char *op) {
    return op && ((op[0] == 'v' || op[0] == 't') && op[1] != '\0');
}

static int cg_const_value(const char *op) {
    return atoi(op + 1);
}

static int cg_align4(int n) {
    return (n + 3) & ~3;
}

static void cg_copy(char *dst, const char *src, int cap) {
    if (!src) src = "";
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}


static void cg_func_label(const char *name, char *buf, int cap) {
    if (strcmp(name, "main") == 0) {
        cg_copy(buf, "main", cap);
    } else {
        snprintf(buf, cap, "__func_%s", name);
        buf[cap - 1] = '\0';
    }
}

static void cg_parse_ir_line(const char *line, CGIR *ir) {
    char lhs[64], rhs[64], a[64], b[64], op[8], label[64], relop[8];
    int size;
    memset(ir, 0, sizeof(CGIR));
    ir->kind = CG_IR_NONE;
    cg_copy(ir->text, line, sizeof(ir->text));

    if (sscanf(line, "FUNCTION %63s :", a) == 1) {
        ir->kind = CG_IR_FUNCTION;
        cg_copy(ir->func, a, sizeof(ir->func));
    } else if (sscanf(line, "PARAM %63s", a) == 1) {
        ir->kind = CG_IR_PARAM;
        cg_copy(ir->result, a, sizeof(ir->result));
    } else if (sscanf(line, "LABEL %63s :", label) == 1) {
        ir->kind = CG_IR_LABEL;
        cg_copy(ir->label, label, sizeof(ir->label));
    } else if (sscanf(line, "DEC %63s %d", a, &size) == 2) {
        ir->kind = CG_IR_DEC;
        cg_copy(ir->result, a, sizeof(ir->result));
        ir->size = size;
    } else if (sscanf(line, "READ %63s", a) == 1) {
        ir->kind = CG_IR_READ;
        cg_copy(ir->result, a, sizeof(ir->result));
    } else if (sscanf(line, "WRITE %63s", a) == 1) {
        ir->kind = CG_IR_WRITE;
        cg_copy(ir->op1, a, sizeof(ir->op1));
    } else if (sscanf(line, "RETURN %63s", a) == 1) {
        ir->kind = CG_IR_RETURN;
        cg_copy(ir->op1, a, sizeof(ir->op1));
    } else if (sscanf(line, "GOTO %63s", label) == 1) {
        ir->kind = CG_IR_GOTO;
        cg_copy(ir->label, label, sizeof(ir->label));
    } else if (sscanf(line, "IF %63s %7s %63s GOTO %63s", a, relop, b, label) == 4) {
        ir->kind = CG_IR_IF;
        cg_copy(ir->op1, a, sizeof(ir->op1));
        cg_copy(ir->op, relop, sizeof(ir->op));
        cg_copy(ir->op2, b, sizeof(ir->op2));
        cg_copy(ir->label, label, sizeof(ir->label));
    } else if (sscanf(line, "ARG %63s", a) == 1) {
        ir->kind = CG_IR_ARG;
        cg_copy(ir->op1, a, sizeof(ir->op1));
    } else if (sscanf(line, "%63s := CALL %63s", lhs, a) == 2) {
        ir->kind = CG_IR_CALL;
        cg_copy(ir->result, lhs, sizeof(ir->result));
        cg_copy(ir->func, a, sizeof(ir->func));
    } else if (sscanf(line, "%63s := &%63s", lhs, rhs) == 2) {
        ir->kind = CG_IR_ADDR;
        cg_copy(ir->result, lhs, sizeof(ir->result));
        cg_copy(ir->op1, rhs, sizeof(ir->op1));
    } else if (sscanf(line, "%63s := *%63s", lhs, rhs) == 2) {
        ir->kind = CG_IR_LOAD;
        cg_copy(ir->result, lhs, sizeof(ir->result));
        cg_copy(ir->op1, rhs, sizeof(ir->op1));
    } else if (sscanf(line, "*%63s := %63s", lhs, rhs) == 2) {
        ir->kind = CG_IR_STORE;
        cg_copy(ir->op1, lhs, sizeof(ir->op1));
        cg_copy(ir->op2, rhs, sizeof(ir->op2));
    } else if (sscanf(line, "%63s := %63s %7s %63s", lhs, a, op, b) == 4) {
        ir->kind = CG_IR_BINOP;
        cg_copy(ir->result, lhs, sizeof(ir->result));
        cg_copy(ir->op1, a, sizeof(ir->op1));
        cg_copy(ir->op, op, sizeof(ir->op));
        cg_copy(ir->op2, b, sizeof(ir->op2));
    } else if (sscanf(line, "%63s := %63s", lhs, rhs) == 2) {
        ir->kind = CG_IR_ASSIGN;
        cg_copy(ir->result, lhs, sizeof(ir->result));
        cg_copy(ir->op1, rhs, sizeof(ir->op1));
    }
}

static int cg_find_var(CGFunc *fn, const char *name) {
    int i;
    for (i = 0; i < fn->var_count; ++i) {
        if (strcmp(fn->vars[i].name, name) == 0) return i;
    }
    return -1;
}

static void cg_add_var(CGFunc *fn, const char *name, int size) {
    int idx;
    if (!cg_is_symbol(name)) return;
    if (size < 4) size = 4;
    size = cg_align4(size);
    idx = cg_find_var(fn, name);
    if (idx >= 0) {
        if (fn->vars[idx].size < size) fn->vars[idx].size = size;
        return;
    }
    if (fn->var_count >= CG_MAX_VARS) {
        fprintf(stderr, "Too many variables in function %s.\n", fn->name);
        exit(1);
    }
    cg_copy(fn->vars[fn->var_count].name, name, sizeof(fn->vars[fn->var_count].name));
    fn->vars[fn->var_count].offset = 0;
    fn->vars[fn->var_count].size = size;
    fn->var_count++;
}

static int cg_var_offset(CGFunc *fn, const char *name) {
    int idx = cg_find_var(fn, name);
    if (idx < 0) {
        fprintf(stderr, "Internal codegen error: unknown variable %s in function %s.\n", name, fn->name);
        return 0;
    }
    return fn->vars[idx].offset;
}

static void cg_collect_operand(CGFunc *fn, const char *op) {
    if (cg_is_symbol(op)) cg_add_var(fn, op, 4);
}

static void cg_collect_function_vars(CGFunc *fn, CGIR irs[]) {
    int i, pidx;
    fn->var_count = 0;
    fn->param_count = 0;
    for (i = fn->start + 1; i < fn->end; ++i) {
        CGIR *ir = &irs[i];
        switch (ir->kind) {
            case CG_IR_PARAM:
                if (fn->param_count < CG_MAX_PARAMS) {
                    cg_copy(fn->params[fn->param_count++], ir->result, 64);
                }
                cg_add_var(fn, ir->result, 4);
                break;
            case CG_IR_DEC:
                cg_add_var(fn, ir->result, ir->size);
                break;
            case CG_IR_ASSIGN:
                cg_add_var(fn, ir->result, 4);
                cg_collect_operand(fn, ir->op1);
                break;
            case CG_IR_BINOP:
                cg_add_var(fn, ir->result, 4);
                cg_collect_operand(fn, ir->op1);
                cg_collect_operand(fn, ir->op2);
                break;
            case CG_IR_ADDR:
                cg_add_var(fn, ir->result, 4);
                cg_add_var(fn, ir->op1, 4);
                break;
            case CG_IR_LOAD:
                cg_add_var(fn, ir->result, 4);
                cg_collect_operand(fn, ir->op1);
                break;
            case CG_IR_STORE:
                cg_collect_operand(fn, ir->op1);
                cg_collect_operand(fn, ir->op2);
                break;
            case CG_IR_IF:
                cg_collect_operand(fn, ir->op1);
                cg_collect_operand(fn, ir->op2);
                break;
            case CG_IR_RETURN:
            case CG_IR_ARG:
            case CG_IR_WRITE:
                cg_collect_operand(fn, ir->op1);
                break;
            case CG_IR_READ:
            case CG_IR_CALL:
                cg_add_var(fn, ir->result, 4);
                break;
            default:
                break;
        }
    }
    for (pidx = 0; pidx < fn->param_count; ++pidx) cg_add_var(fn, fn->params[pidx], 4);
}

static void cg_layout_function(CGFunc *fn) {
    int i;
    int off = 8;
    for (i = 0; i < fn->var_count; ++i) {
        off += cg_align4(fn->vars[i].size);
        fn->vars[i].offset = off;
    }
    fn->frame_size = cg_align4(off);
    if (fn->frame_size < 8) fn->frame_size = 8;
}

static void cg_emit_load_operand(FILE *out, CGFunc *fn, const char *op, const char *reg) {
    if (cg_is_const(op)) {
        fprintf(out, "  li %s, %d\n", reg, cg_const_value(op));
    } else {
        fprintf(out, "  lw %s, -%d($fp)\n", reg, cg_var_offset(fn, op));
    }
}

static void cg_emit_store_var(FILE *out, CGFunc *fn, const char *var, const char *reg) {
    fprintf(out, "  sw %s, -%d($fp)\n", reg, cg_var_offset(fn, var));
}

static void cg_emit_address(FILE *out, CGFunc *fn, const char *var, const char *reg) {
    fprintf(out, "  addi %s, $fp, -%d\n", reg, cg_var_offset(fn, var));
}

static void cg_emit_real_epilogue(FILE *out, int frame_size) {
    fprintf(out, "  lw $ra, %d($sp)\n", frame_size - 4);
    fprintf(out, "  lw $fp, %d($sp)\n", frame_size - 8);
    fprintf(out, "  addi $sp, $sp, %d\n", frame_size);
    fprintf(out, "  jr $ra\n");
}

static const char *cg_branch_op(const char *relop) {
    if (strcmp(relop, "==") == 0) return "beq";
    if (strcmp(relop, "!=") == 0) return "bne";
    if (strcmp(relop, ">") == 0) return "bgt";
    if (strcmp(relop, "<") == 0) return "blt";
    if (strcmp(relop, ">=") == 0) return "bge";
    if (strcmp(relop, "<=") == 0) return "ble";
    return "bne";
}

static void cg_emit_function(FILE *out, CGFunc *fn, CGIR irs[]) {
    char pending_args[CG_MAX_ARGS][64];
    char func_label[128];
    int pending_count = 0;
    int i, j;

    cg_func_label(fn->name, func_label, sizeof(func_label));
    fprintf(out, "\n%s:\n", func_label);
    fprintf(out, "  addi $sp, $sp, -%d\n", fn->frame_size);
    fprintf(out, "  sw $ra, %d($sp)\n", fn->frame_size - 4);
    fprintf(out, "  sw $fp, %d($sp)\n", fn->frame_size - 8);
    fprintf(out, "  addi $fp, $sp, %d\n", fn->frame_size);

    for (i = 0; i < fn->param_count; ++i) {
        fprintf(out, "  lw $t0, %d($fp)\n", i * 4);
        cg_emit_store_var(out, fn, fn->params[i], "$t0");
    }

    for (i = fn->start + 1; i < fn->end; ++i) {
        CGIR *ir = &irs[i];
        switch (ir->kind) {
            case CG_IR_PARAM:
            case CG_IR_DEC:
                break;
            case CG_IR_LABEL:
                fprintf(out, "%s:\n", ir->label);
                break;
            case CG_IR_ASSIGN:
                cg_emit_load_operand(out, fn, ir->op1, "$t0");
                cg_emit_store_var(out, fn, ir->result, "$t0");
                break;
            case CG_IR_ADDR:
                cg_emit_address(out, fn, ir->op1, "$t0");
                cg_emit_store_var(out, fn, ir->result, "$t0");
                break;
            case CG_IR_LOAD:
                cg_emit_load_operand(out, fn, ir->op1, "$t0");
                fprintf(out, "  lw $t1, 0($t0)\n");
                cg_emit_store_var(out, fn, ir->result, "$t1");
                break;
            case CG_IR_STORE:
                cg_emit_load_operand(out, fn, ir->op1, "$t0");
                cg_emit_load_operand(out, fn, ir->op2, "$t1");
                fprintf(out, "  sw $t1, 0($t0)\n");
                break;
            case CG_IR_BINOP:
                cg_emit_load_operand(out, fn, ir->op1, "$t0");
                cg_emit_load_operand(out, fn, ir->op2, "$t1");
                if (strcmp(ir->op, "+") == 0) {
                    fprintf(out, "  add $t2, $t0, $t1\n");
                } else if (strcmp(ir->op, "-") == 0) {
                    fprintf(out, "  sub $t2, $t0, $t1\n");
                } else if (strcmp(ir->op, "*") == 0) {
                    fprintf(out, "  mul $t2, $t0, $t1\n");
                } else {
                    fprintf(out, "  div $t0, $t1\n");
                    fprintf(out, "  mflo $t2\n");
                }
                cg_emit_store_var(out, fn, ir->result, "$t2");
                break;
            case CG_IR_GOTO:
                fprintf(out, "  j %s\n", ir->label);
                break;
            case CG_IR_IF:
                cg_emit_load_operand(out, fn, ir->op1, "$t0");
                cg_emit_load_operand(out, fn, ir->op2, "$t1");
                fprintf(out, "  %s $t0, $t1, %s\n", cg_branch_op(ir->op), ir->label);
                break;
            case CG_IR_RETURN:
                if (strcmp(fn->name, "main") == 0) {
                    fprintf(out, "  li $v0, 10\n");
                    fprintf(out, "  syscall\n");
                } else {
                    cg_emit_load_operand(out, fn, ir->op1, "$v0");
                    cg_emit_real_epilogue(out, fn->frame_size);
                }
                break;
            case CG_IR_ARG:
                if (pending_count < CG_MAX_ARGS) {
                    cg_copy(pending_args[pending_count++], ir->op1, 64);
                }
                break;
            case CG_IR_CALL:
                if (pending_count > 0) fprintf(out, "  addi $sp, $sp, -%d\n", pending_count * 4);
                for (j = 0; j < pending_count; ++j) {
                    cg_emit_load_operand(out, fn, pending_args[pending_count - 1 - j], "$t0");
                    fprintf(out, "  sw $t0, %d($sp)\n", j * 4);
                }
                {
                    char callee_label[128];
                    cg_func_label(ir->func, callee_label, sizeof(callee_label));
                    fprintf(out, "  jal %s\n", callee_label);
                }
                if (pending_count > 0) fprintf(out, "  addi $sp, $sp, %d\n", pending_count * 4);
                pending_count = 0;
                cg_emit_store_var(out, fn, ir->result, "$v0");
                break;
            case CG_IR_READ:
                fprintf(out, "  li $v0, 4\n");
                fprintf(out, "  la $a0, _prompt\n");
                fprintf(out, "  syscall\n");
                fprintf(out, "  li $v0, 5\n");
                fprintf(out, "  syscall\n");
                cg_emit_store_var(out, fn, ir->result, "$v0");
                break;
            case CG_IR_WRITE:
                cg_emit_load_operand(out, fn, ir->op1, "$a0");
                fprintf(out, "  li $v0, 1\n");
                fprintf(out, "  syscall\n");
                fprintf(out, "  li $v0, 4\n");
                fprintf(out, "  la $a0, _ret\n");
                fprintf(out, "  syscall\n");
                fprintf(out, "  move $v0, $0\n");
                break;
            default:
                break;
        }
    }
}

void generate_mips_from_ir(FILE *ir_file, const char *out_path) {
    static CGIR irs[CG_MAX_INST];
    static CGFunc funcs[CG_MAX_FUNCS];
    char line[256];
    int inst_count = 0;
    int func_count = 0;
    int i;
    FILE *out;

    rewind(ir_file);
    while (fgets(line, sizeof(line), ir_file)) {
        cg_trim(line);
        if (line[0] == '\0') continue;
        if (inst_count >= CG_MAX_INST) {
            fprintf(stderr, "Too many IR instructions.\n");
            return;
        }
        cg_parse_ir_line(line, &irs[inst_count]);
        if (irs[inst_count].kind == CG_IR_FUNCTION) {
            if (func_count >= CG_MAX_FUNCS) {
                fprintf(stderr, "Too many functions.\n");
                return;
            }
            memset(&funcs[func_count], 0, sizeof(CGFunc));
            cg_copy(funcs[func_count].name, irs[inst_count].func, sizeof(funcs[func_count].name));
            funcs[func_count].start = inst_count;
            if (func_count > 0) funcs[func_count - 1].end = inst_count;
            func_count++;
        }
        inst_count++;
    }
    if (func_count > 0) funcs[func_count - 1].end = inst_count;

    for (i = 0; i < func_count; ++i) {
        cg_collect_function_vars(&funcs[i], irs);
        cg_layout_function(&funcs[i]);
    }

    out = fopen(out_path, "w");
    if (!out) {
        perror(out_path);
        return;
    }
    fprintf(out, ".data\n");
    fprintf(out, "_prompt: .asciiz \"Enter an integer:\"\n");
    fprintf(out, "_ret: .asciiz \"\\n\"\n");
    fprintf(out, ".globl main\n");
    fprintf(out, ".text\n");
    for (i = 0; i < func_count; ++i) {
        cg_emit_function(out, &funcs[i], irs);
    }
    fclose(out);
}

