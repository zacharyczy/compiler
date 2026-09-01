#include "optimizer.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IR_MAX_TOKEN 64
#define IR_MAX_LINE 256
#define IR_MAX_SUCC 4
#define IR_MAX_ITER 8

typedef enum {
    IR_NONE,
    IR_FUNCTION,
    IR_PARAM,
    IR_LABEL,
    IR_DEC,
    IR_ASSIGN,
    IR_BINOP,
    IR_ADDR,
    IR_LOAD,
    IR_STORE,
    IR_GOTO,
    IR_IF,
    IR_RETURN,
    IR_ARG,
    IR_CALL,
    IR_READ,
    IR_WRITE,
    IR_UNKNOWN
} IRKind;

typedef struct {
    IRKind kind;
    char text[IR_MAX_LINE];
    char result[IR_MAX_TOKEN];
    char op1[IR_MAX_TOKEN];
    char op2[IR_MAX_TOKEN];
    char op[16];
    char label[IR_MAX_TOKEN];
    char func[IR_MAX_TOKEN];
    int size;
    int block;
    int moved_to;
} Instr;

typedef struct {
    char name[IR_MAX_TOKEN];
    Instr *ins;
    int count;
    int cap;
} Function;

typedef struct {
    Function *funcs;
    int count;
    int cap;
} Program;

typedef struct {
    int start;
    int end;
    int nsucc;
    int succ[IR_MAX_SUCC];
    int *pred;
    int npred;
    int pred_cap;
    int reachable;
    int removed;
    char first_label[IR_MAX_TOKEN];
} Block;

typedef struct {
    char name[IR_MAX_TOKEN];
    int block;
} LabelMap;

typedef struct {
    Function *fn;
    Block *blocks;
    int block_count;
    LabelMap *labels;
    int label_count;
    int *instr_block;
} CFG;

typedef unsigned long long Bits;


static void trim(char *s) {
    int n = (int)strlen(s);
    int i = 0;
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) {
        s[--n] = '\0';
    }
    while (s[i] == ' ' || s[i] == '\t') ++i;
    if (i > 0) memmove(s, s + i, strlen(s + i) + 1);
}

static void copy_token(char *dst, const char *src) {
    if (!src) src = "";
    strncpy(dst, src, IR_MAX_TOKEN - 1);
    dst[IR_MAX_TOKEN - 1] = '\0';
}

static int is_const_token(const char *s) {
    return s && s[0] == '#';
}

static int is_var_token(const char *s) {
    return s && (s[0] == 'v' || s[0] == 't') && s[1] != '\0';
}

static int is_temp_token(const char *s) {
    return s && s[0] == 't' && s[1] != '\0';
}

static int is_terminal_kind(IRKind k) {
    return k == IR_GOTO || k == IR_IF || k == IR_RETURN;
}

static Instr parse_ir_line(const char *src) {
    Instr ir;
    char lhs[IR_MAX_TOKEN], rhs[IR_MAX_TOKEN], a[IR_MAX_TOKEN], b[IR_MAX_TOKEN];
    char op[16], label[IR_MAX_TOKEN], relop[16];
    int size;

    memset(&ir, 0, sizeof(ir));
    ir.kind = IR_UNKNOWN;
    ir.block = -1;
    ir.moved_to = -1;
    copy_token(ir.text, src);

    if (sscanf(src, "FUNCTION %63s :", a) == 1) {
        ir.kind = IR_FUNCTION;
        copy_token(ir.func, a);
    } else if (sscanf(src, "PARAM %63s", a) == 1) {
        ir.kind = IR_PARAM;
        copy_token(ir.result, a);
    } else if (sscanf(src, "LABEL %63s :", label) == 1) {
        ir.kind = IR_LABEL;
        copy_token(ir.label, label);
    } else if (sscanf(src, "DEC %63s %d", a, &size) == 2) {
        ir.kind = IR_DEC;
        copy_token(ir.result, a);
        ir.size = size;
    } else if (sscanf(src, "READ %63s", a) == 1) {
        ir.kind = IR_READ;
        copy_token(ir.result, a);
    } else if (sscanf(src, "WRITE %63s", a) == 1) {
        ir.kind = IR_WRITE;
        copy_token(ir.op1, a);
    } else if (sscanf(src, "RETURN %63s", a) == 1) {
        ir.kind = IR_RETURN;
        copy_token(ir.op1, a);
    } else if (sscanf(src, "GOTO %63s", label) == 1) {
        ir.kind = IR_GOTO;
        copy_token(ir.label, label);
    } else if (sscanf(src, "IF %63s %15s %63s GOTO %63s", a, relop, b, label) == 4) {
        ir.kind = IR_IF;
        copy_token(ir.op1, a);
        copy_token(ir.op, relop);
        copy_token(ir.op2, b);
        copy_token(ir.label, label);
    } else if (sscanf(src, "ARG %63s", a) == 1) {
        ir.kind = IR_ARG;
        copy_token(ir.op1, a);
    } else if (sscanf(src, "%63s := CALL %63s", lhs, a) == 2) {
        ir.kind = IR_CALL;
        copy_token(ir.result, lhs);
        copy_token(ir.func, a);
    } else if (sscanf(src, "*%63s := %63s", lhs, rhs) == 2) {
        ir.kind = IR_STORE;
        copy_token(ir.op1, lhs);
        copy_token(ir.op2, rhs);
    } else if (sscanf(src, "%63s := %63s %15s %63s", lhs, a, op, b) == 4) {
        ir.kind = IR_BINOP;
        copy_token(ir.result, lhs);
        copy_token(ir.op1, a);
        copy_token(ir.op, op);
        copy_token(ir.op2, b);
    } else if (sscanf(src, "%63s := &%63s", lhs, rhs) == 2) {
        ir.kind = IR_ADDR;
        copy_token(ir.result, lhs);
        copy_token(ir.op1, rhs);
    } else if (sscanf(src, "%63s := *%63s", lhs, rhs) == 2) {
        ir.kind = IR_LOAD;
        copy_token(ir.result, lhs);
        copy_token(ir.op1, rhs);
    } else if (sscanf(src, "%63s := %63s", lhs, rhs) == 2) {
        ir.kind = IR_ASSIGN;
        copy_token(ir.result, lhs);
        copy_token(ir.op1, rhs);
    }
    return ir;
}

static void program_init(Program *p) {
    p->funcs = NULL;
    p->count = 0;
    p->cap = 0;
}

static Function *program_add_function(Program *p, const char *name) {
    Function *f;
    if (p->count == p->cap) {
        p->cap = p->cap ? p->cap * 2 : 8;
        p->funcs = (Function *)realloc(p->funcs, sizeof(Function) * p->cap);
        if (!p->funcs) exit(1);
    }
    f = &p->funcs[p->count++];
    memset(f, 0, sizeof(*f));
    copy_token(f->name, name ? name : "");
    return f;
}

static void function_push(Function *f, Instr ir) {
    if (f->count == f->cap) {
        f->cap = f->cap ? f->cap * 2 : 128;
        f->ins = (Instr *)realloc(f->ins, sizeof(Instr) * f->cap);
        if (!f->ins) exit(1);
    }
    f->ins[f->count++] = ir;
}

static void program_free(Program *p) {
    int i;
    for (i = 0; i < p->count; ++i) free(p->funcs[i].ins);
    free(p->funcs);
    p->funcs = NULL;
    p->count = p->cap = 0;
}

static int read_program(const char *path, Program *p) {
    FILE *in = fopen(path, "r");
    char line[IR_MAX_LINE];
    Function *cur = NULL;
    if (!in) {
        perror(path);
        return 1;
    }
    program_init(p);
    while (fgets(line, sizeof(line), in)) {
        Instr ir;
        trim(line);
        if (line[0] == '\0') continue;
        ir = parse_ir_line(line);
        if (ir.kind == IR_FUNCTION) {
            cur = program_add_function(p, ir.func);
        } else if (!cur) {
            cur = program_add_function(p, "");
        }
        function_push(cur, ir);
    }
    fclose(in);
    return 0;
}

static int first_code_index(Function *fn) {
    int i;
    for (i = 0; i < fn->count; ++i) {
        if (fn->ins[i].kind != IR_FUNCTION && fn->ins[i].kind != IR_PARAM) return i;
    }
    return fn->count;
}

static void cfg_add_pred(Block *b, int pred) {
    if (b->npred == b->pred_cap) {
        b->pred_cap = b->pred_cap ? b->pred_cap * 2 : 4;
        b->pred = (int *)realloc(b->pred, sizeof(int) * b->pred_cap);
        if (!b->pred) exit(1);
    }
    b->pred[b->npred++] = pred;
}

static void cfg_add_succ(CFG *cfg, int from, int to) {
    Block *b;
    int i;
    if (to < 0 || to >= cfg->block_count) return;
    b = &cfg->blocks[from];
    for (i = 0; i < b->nsucc; ++i) if (b->succ[i] == to) return;
    if (b->nsucc < IR_MAX_SUCC) b->succ[b->nsucc++] = to;
}

static int cfg_label_block(CFG *cfg, const char *label) {
    int i;
    for (i = 0; i < cfg->label_count; ++i) {
        if (strcmp(cfg->labels[i].name, label) == 0) return cfg->labels[i].block;
    }
    return -1;
}

static const char *cfg_block_first_label(CFG *cfg, int block) {
    if (block < 0 || block >= cfg->block_count) return NULL;
    if (cfg->blocks[block].first_label[0] == '\0') return NULL;
    return cfg->blocks[block].first_label;
}

static void cfg_free(CFG *cfg) {
    int i;
    if (!cfg) return;
    for (i = 0; i < cfg->block_count; ++i) free(cfg->blocks[i].pred);
    free(cfg->blocks);
    free(cfg->labels);
    free(cfg->instr_block);
    memset(cfg, 0, sizeof(*cfg));
}

static void cfg_build(Function *fn, CFG *cfg) {
    int *leader;
    int *leaders;
    int nleaders = 0;
    int i, b;
    int first = first_code_index(fn);

    memset(cfg, 0, sizeof(*cfg));
    cfg->fn = fn;
    cfg->instr_block = (int *)malloc(sizeof(int) * (fn->count ? fn->count : 1));
    leader = (int *)calloc((size_t)(fn->count ? fn->count : 1), sizeof(int));
    if (!cfg->instr_block || !leader) exit(1);
    for (i = 0; i < fn->count; ++i) {
        cfg->instr_block[i] = -1;
        fn->ins[i].block = -1;
    }
    if (first >= fn->count) {
        free(leader);
        return;
    }

    leader[first] = 1;
    for (i = first; i < fn->count; ++i) {
        if (fn->ins[i].kind == IR_LABEL) leader[i] = 1;
        if (i + 1 < fn->count && is_terminal_kind(fn->ins[i].kind)) leader[i + 1] = 1;
    }

    leaders = (int *)malloc(sizeof(int) * fn->count);
    if (!leaders) exit(1);
    for (i = first; i < fn->count; ++i) {
        if (leader[i]) leaders[nleaders++] = i;
    }
    cfg->blocks = (Block *)calloc((size_t)nleaders, sizeof(Block));
    if (!cfg->blocks) exit(1);
    cfg->block_count = nleaders;
    for (b = 0; b < nleaders; ++b) {
        int end = (b + 1 < nleaders) ? leaders[b + 1] - 1 : fn->count - 1;
        cfg->blocks[b].start = leaders[b];
        cfg->blocks[b].end = end;
        for (i = leaders[b]; i <= end; ++i) {
            cfg->instr_block[i] = b;
            fn->ins[i].block = b;
        }
        for (i = leaders[b]; i <= end; ++i) {
            if (fn->ins[i].kind == IR_LABEL) {
                if (cfg->blocks[b].first_label[0] == '\0') copy_token(cfg->blocks[b].first_label, fn->ins[i].label);
                cfg->labels = (LabelMap *)realloc(cfg->labels, sizeof(LabelMap) * (cfg->label_count + 1));
                if (!cfg->labels) exit(1);
                copy_token(cfg->labels[cfg->label_count].name, fn->ins[i].label);
                cfg->labels[cfg->label_count].block = b;
                cfg->label_count++;
            }
        }
    }

    for (b = 0; b < cfg->block_count; ++b) {
        Instr *last = &fn->ins[cfg->blocks[b].end];
        if (last->kind == IR_GOTO) {
            cfg_add_succ(cfg, b, cfg_label_block(cfg, last->label));
        } else if (last->kind == IR_IF) {
            cfg_add_succ(cfg, b, cfg_label_block(cfg, last->label));
            if (b + 1 < cfg->block_count) cfg_add_succ(cfg, b, b + 1);
        } else if (last->kind != IR_RETURN) {
            if (b + 1 < cfg->block_count) cfg_add_succ(cfg, b, b + 1);
        }
    }
    for (b = 0; b < cfg->block_count; ++b) {
        for (i = 0; i < cfg->blocks[b].nsucc; ++i) cfg_add_pred(&cfg->blocks[cfg->blocks[b].succ[i]], b);
    }

    free(leaders);
    free(leader);
}

static void cfg_mark_reachable(CFG *cfg) {
    int *stack;
    int top = 0;
    int i;
    if (cfg->block_count == 0) return;
    stack = (int *)malloc(sizeof(int) * cfg->block_count);
    if (!stack) exit(1);
    cfg->blocks[0].reachable = 1;
    stack[top++] = 0;
    while (top > 0) {
        int b = stack[--top];
        for (i = 0; i < cfg->blocks[b].nsucc; ++i) {
            int s = cfg->blocks[b].succ[i];
            if (!cfg->blocks[s].reachable) {
                cfg->blocks[s].reachable = 1;
                stack[top++] = s;
            }
        }
    }
    free(stack);
}

static int bit_words(int nbits) {
    return (nbits + 63) / 64;
}

static void bits_set(Bits *bits, int idx) {
    bits[idx >> 6] |= ((Bits)1 << (idx & 63));
}

static void bits_clear_all(Bits *bits, int words) {
    int i;
    for (i = 0; i < words; ++i) bits[i] = 0;
}

static void bits_set_all(Bits *bits, int nbits, int words) {
    int i;
    for (i = 0; i < words; ++i) bits[i] = ~(Bits)0;
    if ((nbits & 63) != 0) bits[words - 1] &= (((Bits)1 << (nbits & 63)) - 1);
}

static int bits_test(const Bits *bits, int idx) {
    return (bits[idx >> 6] >> (idx & 63)) & 1U;
}

static int bits_equal(const Bits *a, const Bits *b, int words) {
    int i;
    for (i = 0; i < words; ++i) if (a[i] != b[i]) return 0;
    return 1;
}

static void bits_copy(Bits *dst, const Bits *src, int words) {
    memcpy(dst, src, sizeof(Bits) * (size_t)words);
}

static Bits *calculate_dominators(CFG *cfg, int *out_words) {
    int n = cfg->block_count;
    int words = bit_words(n);
    Bits *dom;
    Bits *tmp;
    int b, p, w, changed = 1;
    if (out_words) *out_words = words;
    if (n == 0) return NULL;
    dom = (Bits *)malloc(sizeof(Bits) * (size_t)n * (size_t)words);
    tmp = (Bits *)malloc(sizeof(Bits) * (size_t)words);
    if (!dom || !tmp) exit(1);

    for (b = 0; b < n; ++b) {
        if (b == 0) {
            bits_clear_all(&dom[b * words], words);
            bits_set(&dom[b * words], b);
        } else {
            bits_set_all(&dom[b * words], n, words);
        }
    }

    while (changed) {
        changed = 0;
        for (b = 1; b < n; ++b) {
            if (cfg->blocks[b].npred == 0) {
                bits_clear_all(tmp, words);
            } else {
                bits_set_all(tmp, n, words);
                for (p = 0; p < cfg->blocks[b].npred; ++p) {
                    int pred = cfg->blocks[b].pred[p];
                    for (w = 0; w < words; ++w) tmp[w] &= dom[pred * words + w];
                }
            }
            bits_set(tmp, b);
            if (!bits_equal(tmp, &dom[b * words], words)) {
                bits_copy(&dom[b * words], tmp, words);
                changed = 1;
            }
        }
    }
    free(tmp);
    return dom;
}

static int dominates(const Bits *dom, int words, int node, int dominator) {
    if (!dom) return 0;
    return bits_test(&dom[node * words], dominator);
}

static char *instr_def(Instr *ir) {
    switch (ir->kind) {
        case IR_ASSIGN:
        case IR_BINOP:
        case IR_ADDR:
        case IR_LOAD:
        case IR_CALL:
        case IR_READ:
            return ir->result;
        default:
            return NULL;
    }
}

static int instr_uses(Instr *ir, char out[][IR_MAX_TOKEN], int cap) {
    int n = 0;
#define ADD_USE(tok) do { if (is_var_token(tok) && n < cap) copy_token(out[n++], tok); } while (0)
    switch (ir->kind) {
        case IR_ASSIGN:
            ADD_USE(ir->op1);
            break;
        case IR_BINOP:
            ADD_USE(ir->op1);
            ADD_USE(ir->op2);
            break;
        case IR_ADDR:
            break;
        case IR_LOAD:
            ADD_USE(ir->op1);
            break;
        case IR_STORE:
            ADD_USE(ir->op1);
            ADD_USE(ir->op2);
            break;
        case IR_IF:
            ADD_USE(ir->op1);
            ADD_USE(ir->op2);
            break;
        case IR_RETURN:
        case IR_ARG:
        case IR_WRITE:
            ADD_USE(ir->op1);
            break;
        default:
            break;
    }
#undef ADD_USE
    return n;
}


static void rebuild_assign(Instr *ir, const char *result, const char *op1) {
    ir->kind = IR_ASSIGN;
    copy_token(ir->result, result);
    copy_token(ir->op1, op1);
    ir->op2[0] = '\0';
    ir->op[0] = '\0';
    snprintf(ir->text, IR_MAX_LINE, "%s := %s", ir->result, ir->op1);
    ir->text[IR_MAX_LINE - 1] = '\0';
}

static void rebuild_binop(Instr *ir, const char *result, const char *op1, const char *op, const char *op2) {
    ir->kind = IR_BINOP;
    copy_token(ir->result, result);
    copy_token(ir->op1, op1);
    copy_token(ir->op, op);
    copy_token(ir->op2, op2);
    snprintf(ir->text, IR_MAX_LINE, "%s := %s %s %s", ir->result, ir->op1, ir->op, ir->op2);
    ir->text[IR_MAX_LINE - 1] = '\0';
}

static void rebuild_if(Instr *ir) {
    snprintf(ir->text, IR_MAX_LINE, "IF %s %s %s GOTO %s", ir->op1, ir->op, ir->op2, ir->label);
    ir->text[IR_MAX_LINE - 1] = '\0';
}

static void rebuild_one_operand(Instr *ir) {
    if (ir->kind == IR_RETURN) {
        snprintf(ir->text, IR_MAX_LINE, "RETURN %s", ir->op1);
    } else if (ir->kind == IR_WRITE) {
        snprintf(ir->text, IR_MAX_LINE, "WRITE %s", ir->op1);
    } else if (ir->kind == IR_ARG) {
        snprintf(ir->text, IR_MAX_LINE, "ARG %s", ir->op1);
    }
    ir->text[IR_MAX_LINE - 1] = '\0';
}

static int parse_const_value(const char *s, int *v) {
    if (!is_const_token(s)) return 0;
    *v = atoi(s + 1);
    return 1;
}

static void make_const_token(char *buf, int v) {
    snprintf(buf, IR_MAX_TOKEN, "#%d", v);
    buf[IR_MAX_TOKEN - 1] = '\0';
}

static int eval_binop_const(const char *op, int a, int b, int *out) {
    if (strcmp(op, "+") == 0) { *out = a + b; return 1; }
    if (strcmp(op, "-") == 0) { *out = a - b; return 1; }
    if (strcmp(op, "*") == 0) { *out = a * b; return 1; }
    if (strcmp(op, "/") == 0) {
        if (b == 0) return 0;
        *out = a / b;
        return 1;
    }
    return 0;
}

static int block_next_start(Function *fn, int start) {
    int i;
    for (i = start + 1; i < fn->count; ++i) {
        if (fn->ins[i].kind == IR_LABEL || fn->ins[i].kind == IR_FUNCTION || fn->ins[i].kind == IR_PARAM) return i;
        if (is_terminal_kind(fn->ins[i - 1].kind)) return i;
    }
    return fn->count;
}

static int local_first_block_start(Function *fn) {
    return first_code_index(fn);
}

typedef struct {
    char name[IR_MAX_TOKEN];
    int known;
    int value;
} ConstBind;

typedef struct {
    char name[IR_MAX_TOKEN];
    char value[IR_MAX_TOKEN];
} CopyBind;

static int const_find(ConstBind *arr, int n, const char *name) {
    int i;
    for (i = 0; i < n; ++i) if (strcmp(arr[i].name, name) == 0) return i;
    return -1;
}

static void const_remove(ConstBind *arr, int *n, const char *name) {
    int i = const_find(arr, *n, name);
    if (i >= 0) arr[i] = arr[--(*n)];
}

static void const_set(ConstBind *arr, int *n, const char *name, int value) {
    int i;
    if (!is_var_token(name)) return;
    i = const_find(arr, *n, name);
    if (i < 0) {
        i = (*n)++;
        copy_token(arr[i].name, name);
    }
    arr[i].known = 1;
    arr[i].value = value;
}

static int const_get(ConstBind *arr, int n, const char *name, int *value) {
    int i = const_find(arr, n, name);
    if (i >= 0 && arr[i].known) {
        *value = arr[i].value;
        return 1;
    }
    return 0;
}

static int copy_find(CopyBind *arr, int n, const char *name) {
    int i;
    for (i = 0; i < n; ++i) if (strcmp(arr[i].name, name) == 0) return i;
    return -1;
}

static void copy_remove_at(CopyBind *arr, int *n, int idx) {
    if (idx >= 0 && idx < *n) arr[idx] = arr[--(*n)];
}

static void copy_invalidate(CopyBind *arr, int *n, const char *def) {
    int i = 0;
    while (i < *n) {
        if (strcmp(arr[i].name, def) == 0 || strcmp(arr[i].value, def) == 0) copy_remove_at(arr, n, i);
        else ++i;
    }
}

static void copy_set(CopyBind *arr, int *n, const char *name, const char *value) {
    int i;
    if (!is_var_token(name)) return;
    i = copy_find(arr, *n, name);
    if (i < 0) {
        i = (*n)++;
        copy_token(arr[i].name, name);
    }
    copy_token(arr[i].value, value);
}

static int copy_get(CopyBind *arr, int n, const char *name, char *value) {
    int guard;
    char cur[IR_MAX_TOKEN];
    if (!is_var_token(name)) return 0;
    copy_token(cur, name);
    for (guard = 0; guard < 32; ++guard) {
        int i = copy_find(arr, n, cur);
        if (i < 0) break;
        copy_token(cur, arr[i].value);
        if (!is_var_token(cur)) break;
    }
    if (strcmp(cur, name) == 0) return 0;
    copy_token(value, cur);
    return 1;
}

static int replace_operand_local(char *op, ConstBind *consts, int nconst, CopyBind *copies, int ncopy) {
    int v;
    char buf[IR_MAX_TOKEN];
    if (!is_var_token(op)) return 0;
    if (const_get(consts, nconst, op, &v)) {
        make_const_token(op, v);
        return 1;
    }
    if (copy_get(copies, ncopy, op, buf)) {
        copy_token(op, buf);
        return 1;
    }
    return 0;
}

static int instr_is_pure_local_def(Instr *ir) {
    return ir->kind == IR_ASSIGN || ir->kind == IR_BINOP;
}
static int token_address_name(const char *tok, char *out) {
    if (tok && tok[0] == '&' && is_var_token(tok + 1)) {
        copy_token(out, tok + 1);
        return 1;
    }
    return 0;
}

static int function_var_address_taken(Function *fn, const char *var) {
    int i;
    char buf[IR_MAX_TOKEN];
    for (i = 0; i < fn->count; ++i) {
        Instr *ir = &fn->ins[i];
        if (ir->kind == IR_ADDR && strcmp(ir->op1, var) == 0) return 1;
        if (ir->kind == IR_BINOP) {
            if (token_address_name(ir->op1, buf) && strcmp(buf, var) == 0) return 1;
            if (token_address_name(ir->op2, buf) && strcmp(buf, var) == 0) return 1;
        }
        if (ir->kind == IR_ASSIGN && token_address_name(ir->op1, buf) && strcmp(buf, var) == 0) return 1;
    }
    return 0;
}


static void local_copy_const_block(Function *fn, int start, int end) {
    ConstBind consts[4096];
    CopyBind copies[4096];
    int nconst = 0, ncopy = 0;
    int i;
    for (i = start; i <= end; ++i) {
        Instr *ir = &fn->ins[i];
        char *d;
        int changed = 0;
        int c1, c2, cv, folded;
        char cbuf[IR_MAX_TOKEN];

        if (ir->kind == IR_LABEL || ir->kind == IR_FUNCTION || ir->kind == IR_PARAM) continue;

        if (ir->kind == IR_ASSIGN) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            if (changed) rebuild_assign(ir, ir->result, ir->op1);
        } else if (ir->kind == IR_BINOP) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            changed |= replace_operand_local(ir->op2, consts, nconst, copies, ncopy);
            folded = parse_const_value(ir->op1, &c1) && parse_const_value(ir->op2, &c2) && eval_binop_const(ir->op, c1, c2, &cv);
            if (!folded && strcmp(ir->op, "+") == 0) {
                if (parse_const_value(ir->op1, &c1) && c1 == 0) { rebuild_assign(ir, ir->result, ir->op2); changed = 0; }
                else if (parse_const_value(ir->op2, &c2) && c2 == 0) { rebuild_assign(ir, ir->result, ir->op1); changed = 0; }
            } else if (!folded && strcmp(ir->op, "-") == 0) {
                if (parse_const_value(ir->op2, &c2) && c2 == 0) { rebuild_assign(ir, ir->result, ir->op1); changed = 0; }
            } else if (!folded && strcmp(ir->op, "*") == 0) {
                if (parse_const_value(ir->op1, &c1) && c1 == 0) { rebuild_assign(ir, ir->result, "#0"); changed = 0; }
                else if (parse_const_value(ir->op2, &c2) && c2 == 0) { rebuild_assign(ir, ir->result, "#0"); changed = 0; }
                else if (parse_const_value(ir->op1, &c1) && c1 == 1) { rebuild_assign(ir, ir->result, ir->op2); changed = 0; }
                else if (parse_const_value(ir->op2, &c2) && c2 == 1) { rebuild_assign(ir, ir->result, ir->op1); changed = 0; }
            } else if (!folded && strcmp(ir->op, "/") == 0) {
                if (parse_const_value(ir->op2, &c2) && c2 == 1) { rebuild_assign(ir, ir->result, ir->op1); changed = 0; }
            }
            if (folded) {
                make_const_token(cbuf, cv);
                rebuild_assign(ir, ir->result, cbuf);
                changed = 0;
            } else if (ir->kind == IR_BINOP && changed) {
                rebuild_binop(ir, ir->result, ir->op1, ir->op, ir->op2);
            }
        } else if (ir->kind == IR_IF) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            changed |= replace_operand_local(ir->op2, consts, nconst, copies, ncopy);
            if (changed) rebuild_if(ir);
        } else if (ir->kind == IR_RETURN || ir->kind == IR_WRITE || ir->kind == IR_ARG) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            if (changed) rebuild_one_operand(ir);
        } else if (ir->kind == IR_STORE) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            changed |= replace_operand_local(ir->op2, consts, nconst, copies, ncopy);
            if (changed) {
                snprintf(ir->text, IR_MAX_LINE, "*%s := %s", ir->op1, ir->op2);
                ir->text[IR_MAX_LINE - 1] = '\0';
            }
        } else if (ir->kind == IR_LOAD) {
            changed |= replace_operand_local(ir->op1, consts, nconst, copies, ncopy);
            if (changed) {
                snprintf(ir->text, IR_MAX_LINE, "%s := *%s", ir->result, ir->op1);
                ir->text[IR_MAX_LINE - 1] = '\0';
            }
        }

        d = instr_def(ir);
        if (d && is_var_token(d)) {
            int val;
            const_remove(consts, &nconst, d);
            copy_invalidate(copies, &ncopy, d);
            if (ir->kind == IR_ASSIGN && !function_var_address_taken(fn, d)) {
                if (parse_const_value(ir->op1, &val)) const_set(consts, &nconst, d, val);
                else if (is_var_token(ir->op1) && !function_var_address_taken(fn, ir->op1)) copy_set(copies, &ncopy, d, ir->op1);
            }
        }
        if (ir->kind == IR_CALL || ir->kind == IR_STORE) {
            /* Conservative memory/external-state barrier. */
            nconst = 0;
            ncopy = 0;
        }
    }
}

typedef struct {
    char op[16];
    char a[IR_MAX_TOKEN];
    char b[IR_MAX_TOKEN];
    char value[IR_MAX_TOKEN];
} ExprBind;

static int expr_same(ExprBind *e, const char *op, const char *a, const char *b) {
    return strcmp(e->op, op) == 0 && strcmp(e->a, a) == 0 && strcmp(e->b, b) == 0;
}

static int op_commutative(const char *op) {
    return strcmp(op, "+") == 0 || strcmp(op, "*") == 0;
}

static void normalize_expr_operands(const char *op, const char *x, const char *y, char *a, char *b) {
    if (op_commutative(op) && strcmp(x, y) > 0) {
        copy_token(a, y);
        copy_token(b, x);
    } else {
        copy_token(a, x);
        copy_token(b, y);
    }
}

static void expr_remove_at(ExprBind *exprs, int *n, int idx) {
    if (idx >= 0 && idx < *n) exprs[idx] = exprs[--(*n)];
}

static void expr_invalidate(ExprBind *exprs, int *n, const char *def) {
    int i = 0;
    while (i < *n) {
        if (strcmp(exprs[i].value, def) == 0 || strcmp(exprs[i].a, def) == 0 || strcmp(exprs[i].b, def) == 0) {
            expr_remove_at(exprs, n, i);
        } else ++i;
    }
}

static void local_cse_block(Function *fn, int start, int end) {
    ExprBind exprs[4096];
    int nexpr = 0;
    int i;
    for (i = start; i <= end; ++i) {
        Instr *ir = &fn->ins[i];
        char *d;
        if (ir->kind == IR_BINOP) {
            char a[IR_MAX_TOKEN], b[IR_MAX_TOKEN];
            int j, found = -1;
            normalize_expr_operands(ir->op, ir->op1, ir->op2, a, b);
            for (j = 0; j < nexpr; ++j) {
                if (expr_same(&exprs[j], ir->op, a, b)) { found = j; break; }
            }
            if (found >= 0) {
                char res[IR_MAX_TOKEN];
                copy_token(res, ir->result);
                rebuild_assign(ir, res, exprs[found].value);
            } else if (nexpr < 4096) {
                copy_token(exprs[nexpr].op, ir->op);
                copy_token(exprs[nexpr].a, a);
                copy_token(exprs[nexpr].b, b);
                copy_token(exprs[nexpr].value, ir->result);
                nexpr++;
            }
        }
        d = instr_def(ir);
        if (d && is_var_token(d)) expr_invalidate(exprs, &nexpr, d);
        if (ir->kind == IR_CALL || ir->kind == IR_READ || ir->kind == IR_STORE) {
            /* Conservative memory/external-state barrier for local value numbering. */
            nexpr = 0;
        }
    }
}

typedef struct {
    char name[IR_MAX_TOKEN];
} VarSetEntry;

static int varset_find(VarSetEntry *set, int n, const char *name) {
    int i;
    for (i = 0; i < n; ++i) if (strcmp(set[i].name, name) == 0) return i;
    return -1;
}

static void varset_add(VarSetEntry *set, int *n, const char *name) {
    if (!is_var_token(name)) return;
    if (varset_find(set, *n, name) >= 0) return;
    copy_token(set[*n].name, name);
    (*n)++;
}

static void varset_remove(VarSetEntry *set, int *n, const char *name) {
    int i = varset_find(set, *n, name);
    if (i >= 0) set[i] = set[--(*n)];
}

static int varset_contains(VarSetEntry *set, int n, const char *name) {
    return varset_find(set, n, name) >= 0;
}

static void add_instr_uses_to_set(Instr *ir, VarSetEntry *set, int *n) {
    char uses[4][IR_MAX_TOKEN];
    int i, m = instr_uses(ir, uses, 4);
    for (i = 0; i < m; ++i) varset_add(set, n, uses[i]);
}

static int dce_can_remove(Instr *ir) {
    return ir->kind == IR_ASSIGN || ir->kind == IR_BINOP;
}

static void local_dce_block(Function *fn, int start, int end, unsigned char *remove) {
    VarSetEntry live[8192];
    VarSetEntry defined[8192];
    int nlive = 0;
    int ndef = 0;
    int i;
    for (i = 0; i < fn->count; ++i) {
        if (i >= start && i <= end) continue;
        add_instr_uses_to_set(&fn->ins[i], live, &nlive);
    }
    /* Values used before their first definition in this basic block may be live
       again when a loop jumps back to the block header.  Keeping them in the
       initial live set prevents deleting updates such as v := v + 1. */
    for (i = start; i <= end; ++i) {
        char uses[4][IR_MAX_TOKEN];
        int u, m = instr_uses(&fn->ins[i], uses, 4);
        char *d;
        for (u = 0; u < m; ++u) {
            if (is_var_token(uses[u]) && !varset_contains(defined, ndef, uses[u])) varset_add(live, &nlive, uses[u]);
        }
        d = instr_def(&fn->ins[i]);
        if (d && is_var_token(d)) varset_add(defined, &ndef, d);
    }
    for (i = end; i >= start; --i) {
        Instr *ir = &fn->ins[i];
        char *d = instr_def(ir);
        if (d && is_var_token(d) && dce_can_remove(ir) && !function_var_address_taken(fn, d) && !varset_contains(live, nlive, d)) {
            remove[i] = 1;
            continue;
        }
        if (d && is_var_token(d)) varset_remove(live, &nlive, d);
        add_instr_uses_to_set(ir, live, &nlive);
    }
}

static void function_compact_removed(Function *fn, unsigned char *remove) {
    int i, j = 0;
    for (i = 0; i < fn->count; ++i) {
        if (!remove[i]) fn->ins[j++] = fn->ins[i];
    }
    fn->count = j;
}

static void optimize_local_mandatory(Function *fn) {
    int iter;
    for (iter = 0; iter < 4; ++iter) {
        int old_count = fn->count;
        int start = local_first_block_start(fn);
        while (start < fn->count) {
            int next = block_next_start(fn, start);
            int end = next - 1;
            if (end >= start) {
                local_copy_const_block(fn, start, end);
                local_cse_block(fn, start, end);
                local_copy_const_block(fn, start, end);
            }
            start = next;
        }
        {
            unsigned char *remove = (unsigned char *)calloc((size_t)(fn->count ? fn->count : 1), 1);
            if (!remove) exit(1);
            start = local_first_block_start(fn);
            while (start < fn->count) {
                int next = block_next_start(fn, start);
                int end = next - 1;
                if (end >= start) local_dce_block(fn, start, end, remove);
                start = next;
            }
            function_compact_removed(fn, remove);
            free(remove);
        }
        if (fn->count == old_count) break;
    }
}

static int instr_is_pure_licm_candidate(Instr *ir) {
    char *d = instr_def(ir);
    if (!d || !is_var_token(d)) return 0;
    if (ir->kind == IR_ASSIGN) return 1;
    if (ir->kind == IR_BINOP) {
        /* Avoid moving division before a loop that might not execute. */
        if (strcmp(ir->op, "/") == 0) return 0;
        return 1;
    }
    return 0;
}

static int instr_dominates_instr(CFG *cfg, const Bits *dom, int words, int def_idx, int use_idx) {
    int db = cfg->instr_block[def_idx];
    int ub = cfg->instr_block[use_idx];
    if (db < 0 || ub < 0) return 0;
    if (db == ub) return def_idx <= use_idx;
    return dominates(dom, words, ub, db);
}

static int count_defs_in_body(Function *fn, CFG *cfg, Bits *body, const char *var, int *first_def) {
    int i, count = 0;
    for (i = 0; i < fn->count; ++i) {
        char *d = instr_def(&fn->ins[i]);
        int b = cfg->instr_block[i];
        if (b >= 0 && bits_test(body, b) && d && strcmp(d, var) == 0) {
            if (first_def) *first_def = i;
            ++count;
        }
    }
    return count;
}

static int all_uses_inside_loop(Function *fn, CFG *cfg, Bits *body, const char *var) {
    int i, u, n;
    char uses[4][IR_MAX_TOKEN];
    for (i = 0; i < fn->count; ++i) {
        int b = cfg->instr_block[i];
        n = instr_uses(&fn->ins[i], uses, 4);
        for (u = 0; u < n; ++u) {
            if (strcmp(uses[u], var) == 0) {
                if (b < 0 || !bits_test(body, b)) return 0;
            }
        }
    }
    return 1;
}

static int def_dominates_all_loop_uses(Function *fn, CFG *cfg, const Bits *dom, int words, Bits *body, const char *var, int def_idx) {
    int i, u, n;
    char uses[4][IR_MAX_TOKEN];
    for (i = 0; i < fn->count; ++i) {
        int b = cfg->instr_block[i];
        if (b < 0 || !bits_test(body, b)) continue;
        n = instr_uses(&fn->ins[i], uses, 4);
        for (u = 0; u < n; ++u) {
            if (strcmp(uses[u], var) == 0 && !instr_dominates_instr(cfg, dom, words, def_idx, i)) return 0;
        }
    }
    return 1;
}


static int operand_is_invariant(Function *fn, CFG *cfg, const Bits *dom, int words, Bits *body, const char *op,
                                const unsigned char *invariant, int cur_idx) {
    int i;
    if (op[0] == '\0' || is_const_token(op)) return 1;
    if (!is_var_token(op)) return 0;
    for (i = 0; i < fn->count; ++i) {
        char *d = instr_def(&fn->ins[i]);
        int b = cfg->instr_block[i];
        if (b < 0 || !bits_test(body, b) || !d || strcmp(d, op) != 0) continue;
        if (!invariant[i]) return 0;
        if (!instr_dominates_instr(cfg, dom, words, i, cur_idx)) return 0;
    }
    return 1;
}

static int stmt_operands_invariant(Function *fn, CFG *cfg, const Bits *dom, int words, Bits *body,
                                   const unsigned char *invariant, int idx) {
    Instr *ir = &fn->ins[idx];
    if (ir->kind == IR_ASSIGN) {
        return operand_is_invariant(fn, cfg, dom, words, body, ir->op1, invariant, idx);
    }
    if (ir->kind == IR_BINOP) {
        return operand_is_invariant(fn, cfg, dom, words, body, ir->op1, invariant, idx) &&
               operand_is_invariant(fn, cfg, dom, words, body, ir->op2, invariant, idx);
    }
    return 0;
}

static int loop_preheader(CFG *cfg, Bits *body, int header) {
    int i, result = -1;
    for (i = 0; i < cfg->blocks[header].npred; ++i) {
        int p = cfg->blocks[header].pred[i];
        if (!bits_test(body, p)) {
            if (result != -1) return -1;
            result = p;
        }
    }
    if (result < 0) return -1;
    if (cfg->blocks[result].nsucc != 1 || cfg->blocks[result].succ[0] != header) return -1;
    return result;
}

static void collect_natural_loop(CFG *cfg, int tail, int header, Bits *body, int words) {
    int *stack = (int *)malloc(sizeof(int) * cfg->block_count);
    int top = 0;
    bits_clear_all(body, words);
    bits_set(body, header);
    bits_set(body, tail);
    stack[top++] = tail;
    while (top > 0) {
        int x = stack[--top];
        int i;
        for (i = 0; i < cfg->blocks[x].npred; ++i) {
            int p = cfg->blocks[x].pred[i];
            if (!bits_test(body, p)) {
                bits_set(body, p);
                if (p != header) stack[top++] = p;
            }
        }
    }
    free(stack);
}

static int has_scheduled_to_block(Function *fn, int block) {
    int i;
    for (i = 0; i < fn->count; ++i) if (fn->ins[i].moved_to == block) return 1;
    return 0;
}

static int perform_licm_on_loop(Function *fn, CFG *cfg, const Bits *dom, int words, Bits *body, int header) {
    unsigned char *invariant;
    unsigned char *selected;
    int changed = 1;
    int moved = 0;
    int preheader = loop_preheader(cfg, body, header);
    int i;

    if (preheader < 0) return 0;
    invariant = (unsigned char *)calloc((size_t)fn->count, 1);
    selected = (unsigned char *)calloc((size_t)fn->count, 1);
    if (!invariant || !selected) exit(1);

    while (changed) {
        changed = 0;
        for (i = 0; i < fn->count; ++i) {
            int b = cfg->instr_block[i];
            char *d;
            if (b < 0 || !bits_test(body, b) || invariant[i]) continue;
            if (!instr_is_pure_licm_candidate(&fn->ins[i])) continue;
            if (!stmt_operands_invariant(fn, cfg, dom, words, body, invariant, i)) continue;
            d = instr_def(&fn->ins[i]);
            if (count_defs_in_body(fn, cfg, body, d, NULL) != 1) continue;
            invariant[i] = 1;
            changed = 1;
        }
    }

    for (i = 0; i < fn->count; ++i) {
        int b = cfg->instr_block[i];
        char *d;
        if (b < 0 || !bits_test(body, b) || !invariant[i]) continue;
        d = instr_def(&fn->ins[i]);
        if (!d) continue;
        if (!all_uses_inside_loop(fn, cfg, body, d)) continue;
        if (!def_dominates_all_loop_uses(fn, cfg, dom, words, body, d, i)) continue;
        selected[i] = 1;
    }

    for (i = 0; i < fn->count; ++i) {
        if (selected[i] && fn->ins[i].moved_to < 0) {
            fn->ins[i].moved_to = preheader;
            moved++;
        }
    }

    free(selected);
    free(invariant);
    return moved;
}

static int optimize_licm(Function *fn, CFG *cfg) {
    int words = 0;
    Bits *dom = calculate_dominators(cfg, &words);
    Bits *body;
    int moved = 0;
    int tail, si;
    if (!dom || cfg->block_count == 0) return 0;
    body = (Bits *)malloc(sizeof(Bits) * (size_t)words);
    if (!body) exit(1);

    for (tail = 0; tail < cfg->block_count; ++tail) {
        for (si = 0; si < cfg->blocks[tail].nsucc; ++si) {
            int header = cfg->blocks[tail].succ[si];
            if (dominates(dom, words, tail, header)) {
                collect_natural_loop(cfg, tail, header, body, words);
                moved += perform_licm_on_loop(fn, cfg, dom, words, body, header);
            }
        }
    }

    free(body);
    free(dom);
    return moved;
}

static int block_visible_nonlabel_count(Function *fn, Block *b, int *only_instr) {
    int i, cnt = 0;
    if (only_instr) *only_instr = -1;
    for (i = b->start; i <= b->end; ++i) {
        if (fn->ins[i].moved_to >= 0) continue;
        if (fn->ins[i].kind == IR_LABEL) continue;
        ++cnt;
        if (only_instr) *only_instr = i;
    }
    return cnt;
}

static int next_output_block_with_label(CFG *cfg, int from) {
    int i;
    for (i = from + 1; i < cfg->block_count; ++i) {
        if (!cfg->blocks[i].reachable || cfg->blocks[i].removed) continue;
        if (cfg->blocks[i].first_label[0] != '\0') return i;
        return -1;
    }
    return -1;
}

/* Store redirects as pairs: redirects[2*i].name = source, redirects[2*i+1].name = target. */
static const char *redirect_label_pair(LabelMap *redirects, int pair_count, const char *label) {
    const char *cur = label;
    int guard;
    for (guard = 0; guard < 64; ++guard) {
        int i, found = 0;
        for (i = 0; i < pair_count; ++i) {
            if (strcmp(redirects[2 * i].name, cur) == 0) {
                cur = redirects[2 * i + 1].name;
                found = 1;
                break;
            }
        }
        if (!found) break;
    }
    return cur;
}

static void add_redirect_pair(LabelMap **redirects, int *pair_count, const char *from, const char *to) {
    int i;
    for (i = 0; i < *pair_count; ++i) {
        if (strcmp((*redirects)[2 * i].name, from) == 0) {
            copy_token((*redirects)[2 * i + 1].name, to);
            return;
        }
    }
    *redirects = (LabelMap *)realloc(*redirects, sizeof(LabelMap) * (size_t)(2 * (*pair_count + 1)));
    if (!*redirects) exit(1);
    copy_token((*redirects)[2 * (*pair_count)].name, from);
    copy_token((*redirects)[2 * (*pair_count) + 1].name, to);
    (*pair_count)++;
}

static void simplify_empty_blocks(Function *fn, CFG *cfg, LabelMap **redirects, int *redirect_pair_count) {
    int changed = 1;
    while (changed) {
        int b;
        changed = 0;
        for (b = 1; b < cfg->block_count; ++b) {
            int only = -1;
            int cnt;
            const char *from;
            const char *to = NULL;
            if (!cfg->blocks[b].reachable || cfg->blocks[b].removed) continue;
            if (cfg->blocks[b].first_label[0] == '\0') continue;
            if (has_scheduled_to_block(fn, b)) continue;
            cnt = block_visible_nonlabel_count(fn, &cfg->blocks[b], &only);
            if (cnt == 0) {
                int nb = next_output_block_with_label(cfg, b);
                if (nb >= 0) to = cfg_block_first_label(cfg, nb);
            } else if (cnt == 1 && fn->ins[only].kind == IR_GOTO) {
                to = redirect_label_pair(*redirects, *redirect_pair_count, fn->ins[only].label);
            }
            from = cfg->blocks[b].first_label;
            if (to && from && strcmp(from, to) != 0) {
                add_redirect_pair(redirects, redirect_pair_count, from, to);
                cfg->blocks[b].removed = 1;
                changed = 1;
            }
        }
    }
}

static int block_terminator_index(Function *fn, Block *b) {
    int i;
    for (i = b->end; i >= b->start; --i) {
        if (fn->ins[i].moved_to >= 0) continue;
        if (is_terminal_kind(fn->ins[i].kind)) return i;
        if (fn->ins[i].kind != IR_LABEL) break;
    }
    return -1;
}

static void output_instr(FILE *out, Instr *ir, LabelMap *redirects, int redirect_pair_count, int skip_redundant, const char *next_label) {
    const char *lab;
    if (ir->kind == IR_GOTO) {
        lab = redirect_label_pair(redirects, redirect_pair_count, ir->label);
        if (skip_redundant && next_label && strcmp(lab, next_label) == 0) return;
        fprintf(out, "GOTO %s\n", lab);
    } else if (ir->kind == IR_IF) {
        lab = redirect_label_pair(redirects, redirect_pair_count, ir->label);
        fprintf(out, "IF %s %s %s GOTO %s\n", ir->op1, ir->op, ir->op2, lab);
    } else {
        fprintf(out, "%s\n", ir->text);
    }
}

static void output_scheduled_moves(FILE *out, Function *fn, int block, LabelMap *redirects, int redirect_pair_count) {
    int i;
    for (i = 0; i < fn->count; ++i) {
        if (fn->ins[i].moved_to == block) output_instr(out, &fn->ins[i], redirects, redirect_pair_count, 0, NULL);
    }
}

static int write_function(FILE *out, Function *fn) {
    CFG cfg;
    LabelMap *redirects = NULL;
    int redirect_pair_count = 0;
    int first = first_code_index(fn);
    int i, b;

    optimize_local_mandatory(fn);
    cfg_build(fn, &cfg);
    cfg_mark_reachable(&cfg);
    optimize_licm(fn, &cfg);
    /* Do not merge empty/goto-only blocks here. Removing a goto-only block is
       unsafe when the previous block falls through into it, e.g. LABEL Lx: GOTO Ly.
       We still skip unreachable blocks and remove only GOTO-to-immediate-next-label
       during output, which is semantics-preserving. */

    for (i = 0; i < first; ++i) fprintf(out, "%s\n", fn->ins[i].text);

    for (b = 0; b < cfg.block_count; ++b) {
        int term;
        int inserted = 0;
        const char *next_label = NULL;
        int nb;
        if (!cfg.blocks[b].reachable || cfg.blocks[b].removed) continue;
        term = block_terminator_index(fn, &cfg.blocks[b]);
        nb = next_output_block_with_label(&cfg, b);
        if (nb >= 0) next_label = cfg_block_first_label(&cfg, nb);
        if (next_label) next_label = redirect_label_pair(redirects, redirect_pair_count, next_label);

        for (i = cfg.blocks[b].start; i <= cfg.blocks[b].end; ++i) {
            if (fn->ins[i].moved_to >= 0) continue;
            if (!inserted && i == term) {
                output_scheduled_moves(out, fn, b, redirects, redirect_pair_count);
                inserted = 1;
            }
            output_instr(out, &fn->ins[i], redirects, redirect_pair_count,
                         fn->ins[i].kind == IR_GOTO, next_label);
        }
        if (!inserted) output_scheduled_moves(out, fn, b, redirects, redirect_pair_count);
    }

    free(redirects);
    cfg_free(&cfg);
    return 0;
}

static int write_program(const char *path, Program *p) {
    FILE *out = fopen(path, "w");
    int i;
    if (!out) {
        perror(path);
        return 1;
    }
    for (i = 0; i < p->count; ++i) write_function(out, &p->funcs[i]);
    fclose(out);
    return 0;
}

int optimize_ir_file(const char *input_path, const char *output_path) {
    Program p;
    int ret;
    if (read_program(input_path, &p) != 0) return 1;
    ret = write_program(output_path, &p);
    program_free(&p);
    return ret;
}
