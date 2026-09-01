%code requires {
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    NODE_PROGRAM, NODE_EXTDEFLIST, NODE_EXTDEF, NODE_EXTDECLIST,
    NODE_SPECIFIER, NODE_STRUCTSPECIFIER, NODE_FUNDEC, NODE_COMPST,
    NODE_DEFLIST, NODE_DEF, NODE_DECLIST, NODE_DEC, NODE_VARDEC,
    NODE_STMTLIST, NODE_STMT, NODE_EXP, NODE_ARGS,
    NODE_VARLIST, NODE_PARAMDEC, NODE_OPTTAG, NODE_TAG,
    NODE_TYPE, NODE_ID, NODE_INT, NODE_FLOAT,
    NODE_RELOP, NODE_ASSIGNOP, NODE_AND, NODE_OR, NODE_PLUS, NODE_MINUS,
    NODE_STAR, NODE_DIV, NODE_IF, NODE_ELSE, NODE_WHILE, NODE_RETURN,
    NODE_STRUCT, NODE_DOT, NODE_LP, NODE_RP, NODE_LC, NODE_RC,
    NODE_SEMI, NODE_COMMA, NODE_LB, NODE_RB, NODE_NOT
} NodeType;

typedef struct ASTNode {
    NodeType type;
    int line;
    char *str_val;
    int int_val;
    double float_val;
    struct ASTNode **children;
    int child_count;
    int child_capacity;
} ASTNode;

ASTNode *new_node(NodeType type, int line);
void add_child(ASTNode *parent, ASTNode *child);
void free_ast(ASTNode *node);
void analyze_semantics(ASTNode *root);
void translate_ir(ASTNode *root, const char *out_path);

extern int yylineno;
extern int yylex(void);
void yyerror(const char *msg);
}

%code {
#include <stdarg.h>
#include "mips.h"

ASTNode *root = NULL;
int has_error = 0;
extern int lexer_error_just_happened;
#include "lex.yy.c"

static char *dupstr(const char *s) {
    size_t n = strlen(s);
    char *p = (char *)malloc(n + 1);
    if (!p) exit(1);
    memcpy(p, s, n + 1);
    return p;
}

typedef enum { TYPE_BASIC, TYPE_ARRAY, TYPE_STRUCT, TYPE_FUNCTION, TYPE_ERROR } TypeKind;
typedef struct Type Type;
typedef struct FieldList FieldList;
typedef struct Symbol Symbol;

enum { BASIC_INT = 0, BASIC_FLOAT = 1 };

struct FieldList {
    char *name;
    Type *type;
    int line;
    FieldList *next;
};

struct Type {
    TypeKind kind;
    int basic;
    Type *elem;
    int array_size;
    FieldList *fields;
    Type *ret;
    FieldList *params;
    char *struct_name;
};

typedef enum { SYM_VAR, SYM_FUNC, SYM_STRUCT } SymbolKind;

struct Symbol {
    char *name;
    SymbolKind kind;
    Type *type;
    int line;
    Symbol *next;
};

typedef struct {
    Type *type;
    int is_lvalue;
} ExpInfo;

static Type builtin_int_type = { TYPE_BASIC, BASIC_INT, NULL, 0, NULL, NULL, NULL, NULL };
static Type builtin_float_type = { TYPE_BASIC, BASIC_FLOAT, NULL, 0, NULL, NULL, NULL, NULL };
static Type builtin_error_type = { TYPE_ERROR, 0, NULL, 0, NULL, NULL, NULL, NULL };

static Symbol *symbol_table = NULL;

static Type *type_int(void) { return &builtin_int_type; }
static Type *type_float(void) { return &builtin_float_type; }
static Type *type_error(void) { return &builtin_error_type; }

static int is_error_type(Type *t) { return t == NULL || t->kind == TYPE_ERROR; }
static int is_int_type(Type *t) { return t && t->kind == TYPE_BASIC && t->basic == BASIC_INT; }
static int is_float_type(Type *t) { return t && t->kind == TYPE_BASIC && t->basic == BASIC_FLOAT; }
static int is_numeric_type(Type *t) { return is_int_type(t) || is_float_type(t); }

static Type *new_type(TypeKind kind) {
    Type *t = (Type *)malloc(sizeof(Type));
    if (!t) exit(1);
    t->kind = kind;
    t->basic = 0;
    t->elem = NULL;
    t->array_size = 0;
    t->fields = NULL;
    t->ret = NULL;
    t->params = NULL;
    t->struct_name = NULL;
    return t;
}

static Type *make_array_type(Type *elem, int size) {
    Type *t = new_type(TYPE_ARRAY);
    t->elem = elem;
    t->array_size = size;
    return t;
}

static Type *make_struct_type(const char *name, FieldList *fields) {
    Type *t = new_type(TYPE_STRUCT);
    if (name) t->struct_name = dupstr(name);
    t->fields = fields;
    return t;
}

static Type *make_function_type(Type *ret, FieldList *params) {
    Type *t = new_type(TYPE_FUNCTION);
    t->ret = ret;
    t->params = params;
    return t;
}

static FieldList *new_field(const char *name, Type *type, int line) {
    FieldList *f = (FieldList *)malloc(sizeof(FieldList));
    if (!f) exit(1);
    f->name = name ? dupstr(name) : NULL;
    f->type = type;
    f->line = line;
    f->next = NULL;
    return f;
}

static void append_field(FieldList **head, FieldList **tail, FieldList *node) {
    if (!node) return;
    if (*head == NULL) {
        *head = *tail = node;
    } else {
        (*tail)->next = node;
        *tail = node;
    }
}

static Symbol *find_symbol(const char *name, SymbolKind kind) {
    Symbol *p = symbol_table;
    while (p) {
        if (p->kind == kind && strcmp(p->name, name) == 0) return p;
        p = p->next;
    }
    return NULL;
}

static Symbol *find_var_symbol(const char *name) { return find_symbol(name, SYM_VAR); }
static Symbol *find_func_symbol(const char *name) { return find_symbol(name, SYM_FUNC); }
static Symbol *find_struct_symbol(const char *name) { return find_symbol(name, SYM_STRUCT); }

static void insert_symbol(const char *name, SymbolKind kind, Type *type, int line) {
    Symbol *s = (Symbol *)malloc(sizeof(Symbol));
    if (!s) exit(1);
    s->name = dupstr(name);
    s->kind = kind;
    s->type = type;
    s->line = line;
    s->next = symbol_table;
    symbol_table = s;
}

static void semantic_error(int type, int line, const char *fmt, ...) {
    va_list ap;
    has_error = 1;
    printf("Error type %d at Line %d: ", type, line);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf(".\n");
}

static int type_equal(Type *a, Type *b);

static int field_list_equal(FieldList *a, FieldList *b) {
    while (a && b) {
        if (!type_equal(a->type, b->type)) return 0;
        a = a->next;
        b = b->next;
    }
    return a == NULL && b == NULL;
}

static int type_equal(Type *a, Type *b) {
    if (is_error_type(a) || is_error_type(b)) return 1;
    if (a == b) return 1;
    if (a->kind != b->kind) return 0;
    switch (a->kind) {
        case TYPE_BASIC:
            return a->basic == b->basic;
        case TYPE_ARRAY:
            return type_equal(a->elem, b->elem);
        case TYPE_STRUCT:
            return field_list_equal(a->fields, b->fields);
        case TYPE_FUNCTION:
            return type_equal(a->ret, b->ret) && field_list_equal(a->params, b->params);
        case TYPE_ERROR:
            return 1;
        default:
            return 0;
    }
}

static FieldList *find_field_by_name(FieldList *fields, const char *name) {
    while (fields) {
        if (fields->name && strcmp(fields->name, name) == 0) return fields;
        fields = fields->next;
    }
    return NULL;
}

static ASTNode *first_child(ASTNode *node, NodeType type) {
    int i;
    if (!node) return NULL;
    for (i = 0; i < node->child_count; ++i) {
        if (node->children[i] && node->children[i]->type == type) return node->children[i];
    }
    return NULL;
}

static void collect_vardec(ASTNode *vardec, char **name, int *line, int dims[], int *dim_count) {
    if (vardec->child_count == 1) {
        ASTNode *id = vardec->children[0];
        *name = id->str_val;
        *line = id->line;
        return;
    }
    dims[(*dim_count)++] = vardec->children[2]->int_val;
    collect_vardec(vardec->children[0], name, line, dims, dim_count);
}

static Type *build_vardec_type(ASTNode *vardec, Type *base, char **name, int *line) {
    int dims[64];
    int dim_count = 0;
    int i;
    Type *t;
    collect_vardec(vardec, name, line, dims, &dim_count);
    t = base;
    for (i = 0; i < dim_count; ++i) {
        t = make_array_type(t, dims[i]);
    }
    return t;
}

static Type *analyze_specifier(ASTNode *specifier, int need_defined_struct);
static FieldList *analyze_varlist(ASTNode *varlist);
static void analyze_compst(ASTNode *compst, Type *return_type);
static ExpInfo analyze_exp(ASTNode *exp);

static FieldList *analyze_struct_deflist(ASTNode *deflist) {
    FieldList *head = NULL, *tail = NULL;
    while (deflist) {
        ASTNode *def;
        ASTNode *specifier;
        ASTNode *declist;
        Type *base;
        if (deflist->child_count < 1) break;
        def = deflist->children[0];
        if (!def || def->child_count < 2) {
            if (deflist->child_count == 1) break;
            deflist = deflist->children[1];
            continue;
        }
        specifier = def->children[0];
        declist = def->children[1];
        base = analyze_specifier(specifier, 1);
        while (declist) {
            ASTNode *dec;
            ASTNode *vardec;
            char *name = NULL;
            int line;
            Type *field_type;
            if (declist->child_count < 1) break;
            dec = declist->children[0];
            if (!dec || dec->child_count < 1) {
                if (declist->child_count == 1) break;
                declist = declist->children[2];
                continue;
            }
            vardec = dec->children[0];
            line = vardec ? vardec->line : def->line;
            field_type = build_vardec_type(vardec, base, &name, &line);
            if (dec->child_count == 3) {
                semantic_error(15, dec->line, "Illegal initialization in struct field '%s'", name);
            }
            if (name && find_field_by_name(head, name)) {
                semantic_error(15, line, "Redefined field '%s'", name);
            } else {
                append_field(&head, &tail, new_field(name, field_type, line));
            }
            if (declist->child_count == 1) break;
            declist = declist->children[2];
        }
        if (deflist->child_count == 1) break;
        deflist = deflist->children[1];
    }
    return head;
}

static Type *analyze_struct_specifier(ASTNode *node, int need_defined_struct) {
    if (node->child_count == 2) {
        ASTNode *tag = node->children[1];
        ASTNode *id = first_child(tag, NODE_ID);
        Symbol *s;
        if (!id) return type_error();
        s = find_struct_symbol(id->str_val);
        if (!s) {
            if (need_defined_struct) {
                semantic_error(17, id->line, "Undefined structure '%s'", id->str_val);
            }
            return type_error();
        }
        return s->type;
    } else {
        ASTNode *opt_tag = first_child(node, NODE_OPTTAG);
        ASTNode *id = opt_tag ? first_child(opt_tag, NODE_ID) : NULL;
        ASTNode *deflist = first_child(node, NODE_DEFLIST);
        char *name = id ? id->str_val : NULL;
        FieldList *fields = analyze_struct_deflist(deflist);
        Type *t = make_struct_type(name, fields);
        if (name) {
            if (find_struct_symbol(name) || find_var_symbol(name)) {
                semantic_error(16, id->line, "Duplicated name '%s'", name);
            } else {
                insert_symbol(name, SYM_STRUCT, t, id->line);
            }
        }
        return t;
    }
}

static Type *analyze_specifier(ASTNode *specifier, int need_defined_struct) {
    ASTNode *child = specifier->children[0];
    if (child->type == NODE_TYPE) {
        if (strcmp(child->str_val, "int") == 0) return type_int();
        return type_float();
    }
    return analyze_struct_specifier(child, need_defined_struct);
}

static void define_variable(const char *name, Type *type, int line) {
    if (find_var_symbol(name) || find_struct_symbol(name)) {
        semantic_error(3, line, "Redefined variable '%s'", name);
        /* Insert an error-typed placeholder so later uses do not cascade into
           undefined-variable errors. */
        if (!find_var_symbol(name)) {
            insert_symbol(name, SYM_VAR, type_error(), line);
        }
        return;
    }
    insert_symbol(name, SYM_VAR, type, line);
}

static FieldList *analyze_paramdec(ASTNode *paramdec) {
    ASTNode *specifier = paramdec->children[0];
    ASTNode *vardec = paramdec->children[1];
    Type *base = analyze_specifier(specifier, 1);
    char *name = NULL;
    int line = vardec->line;
    Type *t = build_vardec_type(vardec, base, &name, &line);
    define_variable(name, t, line);
    return new_field(name, t, line);
}

static FieldList *analyze_varlist(ASTNode *varlist) {
    FieldList *head = NULL, *tail = NULL;
    while (varlist) {
        FieldList *param = analyze_paramdec(varlist->children[0]);
        append_field(&head, &tail, param);
        if (varlist->child_count == 1) break;
        varlist = varlist->children[2];
    }
    return head;
}

static void analyze_fundec(ASTNode *fundec, Type *return_type) {
    ASTNode *id = fundec->children[0];
    FieldList *params = NULL;
    Type *func_type;
    if (fundec->child_count == 4) params = analyze_varlist(fundec->children[2]);
    func_type = make_function_type(return_type, params);
    if (find_func_symbol(id->str_val)) {
        semantic_error(4, id->line, "Redefined function '%s'", id->str_val);
    } else {
        insert_symbol(id->str_val, SYM_FUNC, func_type, id->line);
    }
}

static void analyze_extdeclist(ASTNode *extdeclist, Type *base) {
    while (extdeclist) {
        ASTNode *vardec = extdeclist->children[0];
        char *name = NULL;
        int line = vardec->line;
        Type *t = build_vardec_type(vardec, base, &name, &line);
        define_variable(name, t, line);
        if (extdeclist->child_count == 1) break;
        extdeclist = extdeclist->children[2];
    }
}

static void analyze_declist(ASTNode *declist, Type *base) {
    while (declist) {
        ASTNode *dec = declist->children[0];
        ASTNode *vardec = dec->children[0];
        char *name = NULL;
        int line = vardec->line;
        Type *var_type = build_vardec_type(vardec, base, &name, &line);
        define_variable(name, var_type, line);
        if (dec->child_count == 3) {
            ExpInfo rhs = analyze_exp(dec->children[2]);
            if (!is_error_type(var_type) && !is_error_type(rhs.type) && !type_equal(var_type, rhs.type)) {
                semantic_error(5, dec->line, "Type mismatched for assignment");
            }
        }
        if (declist->child_count == 1) break;
        declist = declist->children[2];
    }
}

static void analyze_deflist(ASTNode *deflist) {
    while (deflist) {
        ASTNode *def;
        Type *base;
        if (deflist->child_count < 1) break;
        def = deflist->children[0];
        if (!def || def->child_count < 2) {
            if (deflist->child_count == 1) break;
            deflist = deflist->children[1];
            continue;
        }
        base = analyze_specifier(def->children[0], 1);
        analyze_declist(def->children[1], base);
        if (deflist->child_count == 1) break;
        deflist = deflist->children[1];
    }
}

static FieldList *collect_arg_types(ASTNode *args) {
    FieldList *head = NULL, *tail = NULL;
    while (args) {
        ExpInfo e = analyze_exp(args->children[0]);
        append_field(&head, &tail, new_field(NULL, e.type, args->children[0]->line));
        if (args->child_count == 1) break;
        args = args->children[2];
    }
    return head;
}

static int arg_list_match(FieldList *a, FieldList *b) {
    while (a && b) {
        if (!type_equal(a->type, b->type)) return 0;
        a = a->next;
        b = b->next;
    }
    return a == NULL && b == NULL;
}

static ExpInfo make_expinfo(Type *type, int is_lvalue) {
    ExpInfo e;
    e.type = type;
    e.is_lvalue = is_lvalue;
    return e;
}

static ExpInfo analyze_exp(ASTNode *exp) {
    ASTNode *c0 = exp->child_count > 0 ? exp->children[0] : NULL;
    if (exp->child_count == 1) {
        if (c0->type == NODE_ID) {
            Symbol *v = find_var_symbol(c0->str_val);
            if (!v) {
                semantic_error(1, c0->line, "Undefined variable '%s'", c0->str_val);
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(v->type, 1);
        }
        if (c0->type == NODE_INT) return make_expinfo(type_int(), 0);
        if (c0->type == NODE_FLOAT) return make_expinfo(type_float(), 0);
    }

    if (exp->child_count == 2) {
        ExpInfo e = analyze_exp(exp->children[1]);
        if (c0->type == NODE_MINUS) {
            if (!is_error_type(e.type) && !is_numeric_type(e.type)) {
                semantic_error(7, exp->line, "Type mismatched for operands");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(e.type, 0);
        }
        if (c0->type == NODE_NOT) {
            if (!is_error_type(e.type) && !is_int_type(e.type)) {
                semantic_error(7, exp->line, "Type mismatched for operands");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(type_int(), 0);
        }
    }

    if (exp->child_count == 3 && exp->children[0]->type == NODE_LP) {
        return analyze_exp(exp->children[1]);
    }

    if (exp->child_count == 3 && exp->children[0]->type == NODE_ID && exp->children[1]->type == NODE_LP) {
        ASTNode *id = exp->children[0];
        Symbol *f = find_func_symbol(id->str_val);
        if (!f) {
            if (find_var_symbol(id->str_val)) {
                semantic_error(11, id->line, "'%s' is not a function", id->str_val);
            } else {
                semantic_error(2, id->line, "Undefined function '%s'", id->str_val);
            }
            return make_expinfo(type_error(), 0);
        }
        if (!arg_list_match(f->type->params, NULL)) {
            semantic_error(9, id->line, "Function '%s' is not applicable for given arguments", id->str_val);
            return make_expinfo(type_error(), 0);
        }
        return make_expinfo(f->type->ret, 0);
    }

    if (exp->child_count == 4 && exp->children[0]->type == NODE_ID && exp->children[1]->type == NODE_LP) {
        ASTNode *id = exp->children[0];
        Symbol *f = find_func_symbol(id->str_val);
        FieldList *args;
        if (!f) {
            if (find_var_symbol(id->str_val)) {
                semantic_error(11, id->line, "'%s' is not a function", id->str_val);
            } else {
                semantic_error(2, id->line, "Undefined function '%s'", id->str_val);
            }
            return make_expinfo(type_error(), 0);
        }
        args = collect_arg_types(exp->children[2]);
        if (!arg_list_match(f->type->params, args)) {
            semantic_error(9, id->line, "Function '%s' is not applicable for given arguments", id->str_val);
            return make_expinfo(type_error(), 0);
        }
        return make_expinfo(f->type->ret, 0);
    }

    if (exp->child_count == 4 && exp->children[1]->type == NODE_LB) {
        ExpInfo arr = analyze_exp(exp->children[0]);
        ExpInfo idx = analyze_exp(exp->children[2]);
        if (!is_error_type(arr.type) && arr.type->kind != TYPE_ARRAY) {
            semantic_error(10, exp->line, "'%s' is not an array", "expression");
            return make_expinfo(type_error(), 0);
        }
        if (!is_error_type(idx.type) && !is_int_type(idx.type)) {
            semantic_error(12, exp->children[2]->line, "Array index is not an integer");
            return make_expinfo(type_error(), 0);
        }
        if (is_error_type(arr.type)) return make_expinfo(type_error(), 0);
        return make_expinfo(arr.type->elem, 1);
    }

    if (exp->child_count == 3 && exp->children[1]->type == NODE_DOT) {
        ExpInfo st = analyze_exp(exp->children[0]);
        ASTNode *id = exp->children[2];
        FieldList *field;
        if (!is_error_type(st.type) && st.type->kind != TYPE_STRUCT) {
            semantic_error(13, exp->line, "Illegal use of '.'");
            return make_expinfo(type_error(), 0);
        }
        if (is_error_type(st.type)) return make_expinfo(type_error(), 0);
        field = find_field_by_name(st.type->fields, id->str_val);
        if (!field) {
            semantic_error(14, id->line, "Non-existent field '%s'", id->str_val);
            return make_expinfo(type_error(), 0);
        }
        return make_expinfo(field->type, 1);
    }

    if (exp->child_count == 3) {
        ExpInfo left = analyze_exp(exp->children[0]);
        ExpInfo right = analyze_exp(exp->children[2]);
        ASTNode *op = exp->children[1];
        if (op->type == NODE_ASSIGNOP) {
            if (is_error_type(left.type) || is_error_type(right.type)) {
                return make_expinfo(type_error(), 0);
            }
            if (!left.is_lvalue) {
                semantic_error(6, exp->line, "The left-hand side of an assignment must be a variable");
                return make_expinfo(type_error(), 0);
            }
            if (!type_equal(left.type, right.type)) {
                semantic_error(5, exp->line, "Type mismatched for assignment");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(left.type, 0);
        }
        if (op->type == NODE_AND || op->type == NODE_OR) {
            if ((!is_error_type(left.type) && !is_int_type(left.type)) ||
                (!is_error_type(right.type) && !is_int_type(right.type))) {
                semantic_error(7, exp->line, "Type mismatched for operands");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(type_int(), 0);
        }
        if (op->type == NODE_RELOP) {
            if ((!is_error_type(left.type) && !is_numeric_type(left.type)) ||
                (!is_error_type(right.type) && !is_numeric_type(right.type)) ||
                (!is_error_type(left.type) && !is_error_type(right.type) && !type_equal(left.type, right.type))) {
                semantic_error(7, exp->line, "Type mismatched for operands");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(type_int(), 0);
        }
        if (op->type == NODE_PLUS || op->type == NODE_MINUS || op->type == NODE_STAR || op->type == NODE_DIV) {
            if ((!is_error_type(left.type) && !is_numeric_type(left.type)) ||
                (!is_error_type(right.type) && !is_numeric_type(right.type)) ||
                (!is_error_type(left.type) && !is_error_type(right.type) && !type_equal(left.type, right.type))) {
                semantic_error(7, exp->line, "Type mismatched for operands");
                return make_expinfo(type_error(), 0);
            }
            return make_expinfo(left.type, 0);
        }
    }

    return make_expinfo(type_error(), 0);
}

static void analyze_stmt(ASTNode *stmt, Type *return_type) {
    if (!stmt || stmt->child_count == 0) return;
    if (stmt->child_count == 2 && stmt->children[1]->type == NODE_SEMI) {
        analyze_exp(stmt->children[0]);
        return;
    }
    if (stmt->child_count == 1 && stmt->children[0]->type == NODE_COMPST) {
        analyze_compst(stmt->children[0], return_type);
        return;
    }
    if (stmt->child_count == 3 && stmt->children[0]->type == NODE_RETURN) {
        ExpInfo e = analyze_exp(stmt->children[1]);
        if (!is_error_type(e.type) && !type_equal(e.type, return_type)) {
            semantic_error(8, stmt->children[0]->line, "Type mismatched for return");
        }
        return;
    }
    if (stmt->children[0]->type == NODE_IF) {
        ExpInfo cond = analyze_exp(stmt->children[2]);
        if (!is_error_type(cond.type) && !is_int_type(cond.type)) {
            semantic_error(7, stmt->children[2]->line, "Type mismatched for operands");
        }
        analyze_stmt(stmt->children[4], return_type);
        if (stmt->child_count == 7) analyze_stmt(stmt->children[6], return_type);
        return;
    }
    if (stmt->children[0]->type == NODE_WHILE) {
        ExpInfo cond = analyze_exp(stmt->children[2]);
        if (!is_error_type(cond.type) && !is_int_type(cond.type)) {
            semantic_error(7, stmt->children[2]->line, "Type mismatched for operands");
        }
        analyze_stmt(stmt->children[4], return_type);
        return;
    }
}

static void analyze_stmtlist(ASTNode *stmtlist, Type *return_type) {
    while (stmtlist) {
        if (stmtlist->child_count < 1) break;
        analyze_stmt(stmtlist->children[0], return_type);
        if (stmtlist->child_count == 1) break;
        stmtlist = stmtlist->children[1];
    }
}

static void analyze_compst(ASTNode *compst, Type *return_type) {
    ASTNode *deflist;
    ASTNode *stmtlist;
    if (!compst) return;
    deflist = first_child(compst, NODE_DEFLIST);
    stmtlist = first_child(compst, NODE_STMTLIST);
    analyze_deflist(deflist);
    analyze_stmtlist(stmtlist, return_type);
}

static void analyze_extdef(ASTNode *extdef) {
    if (!extdef || extdef->child_count < 1) return;
    if (extdef->child_count >= 2 && extdef->children[1]->type == NODE_EXTDECLIST) {
        Type *base = analyze_specifier(extdef->children[0], 1);
        analyze_extdeclist(extdef->children[1], base);
        return;
    }
    if (extdef->child_count >= 3 && extdef->children[1]->type == NODE_FUNDEC) {
        Type *ret = analyze_specifier(extdef->children[0], 0);
        analyze_fundec(extdef->children[1], ret);
        analyze_compst(extdef->children[2], ret);
        return;
    }
    if (extdef->child_count >= 2 && extdef->children[1]->type == NODE_SEMI) {
        analyze_specifier(extdef->children[0], 0);
    }
}

static void analyze_extdeflist(ASTNode *list) {
    while (list) {
        if (list->child_count < 1) break;
        analyze_extdef(list->children[0]);
        if (list->child_count == 1) break;
        list = list->children[1];
    }
}

static void add_builtin_functions(void) {
    FieldList *write_param;
    if (!find_func_symbol("read")) {
        insert_symbol("read", SYM_FUNC, make_function_type(type_int(), NULL), 0);
    }
    if (!find_func_symbol("write")) {
        write_param = new_field("x", type_int(), 0);
        insert_symbol("write", SYM_FUNC, make_function_type(type_int(), write_param), 0);
    }
}

void analyze_semantics(ASTNode *root_node) {
    symbol_table = NULL;
    add_builtin_functions();
    if (!root_node) return;
    if (root_node->child_count > 0) {
        analyze_extdeflist(root_node->children[0]);
    }
}

/* ========================= Lab 3: Intermediate Representation generation ========================= */

typedef struct VarInfo VarInfo;
struct VarInfo {
    char *src;
    char *ir;
    Type *type;
    int is_param;
    VarInfo *next;
};

typedef struct {
    char *addr;
    Type *type;
} AddrInfo;

static FILE *ir_out = NULL;
static VarInfo *ir_vars = NULL;
static int temp_no = 1;
static int label_no = 1;
static int var_no = 1;
static int cannot_translate = 0;

static char *ir_sprintf(const char *fmt, ...) {
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    return dupstr(buf);
}

static char *new_temp(void) { return ir_sprintf("t%d", temp_no++); }
static char *new_label(void) { return ir_sprintf("label%d", label_no++); }
static char *new_ir_var(void) { return ir_sprintf("v%d", var_no++); }
static char *ir_const(int value) { return ir_sprintf("#%d", value); }

static void emit_ir(const char *fmt, ...) {
    va_list ap;
    if (!ir_out) return;
    va_start(ap, fmt);
    vfprintf(ir_out, fmt, ap);
    va_end(ap);
    fprintf(ir_out, "\n");
}

static VarInfo *find_ir_var(const char *src) {
    VarInfo *p = ir_vars;
    while (p) {
        if (strcmp(p->src, src) == 0) return p;
        p = p->next;
    }
    return NULL;
}

static VarInfo *add_ir_var(const char *src, Type *type, int is_param) {
    VarInfo *old = find_ir_var(src);
    VarInfo *v;
    if (old) {
        if (is_param) old->is_param = 1;
        return old;
    }
    v = (VarInfo *)malloc(sizeof(VarInfo));
    if (!v) exit(1);
    v->src = dupstr(src);
    v->ir = new_ir_var();
    v->type = type;
    v->is_param = is_param;
    v->next = ir_vars;
    ir_vars = v;
    return v;
}

static Type *ir_var_type(const char *name) {
    Symbol *s = find_var_symbol(name);
    return s ? s->type : type_error();
}

static int ir_is_aggregate(Type *t) {
    return t && (t->kind == TYPE_ARRAY || t->kind == TYPE_STRUCT);
}

static int ir_type_size(Type *t) {
    int sum;
    FieldList *f;
    if (is_error_type(t)) return 4;
    switch (t->kind) {
        case TYPE_BASIC: return 4;
        case TYPE_ARRAY: return t->array_size * ir_type_size(t->elem);
        case TYPE_STRUCT:
            sum = 0;
            for (f = t->fields; f; f = f->next) sum += ir_type_size(f->type);
            return sum;
        default: return 4;
    }
}

/*
 * This submission implements the compulsory part plus optional 4.1 only.
 * Therefore, local one-dimensional arrays are still accepted, but the two
 * features belonging to optional 4.2 are rejected before IR generation:
 *   1) array-typed function parameters;
 *   2) variables or fields whose array rank is greater than one.
 */
static int ir_array_rank(Type *t) {
    int rank = 0;
    while (t && t->kind == TYPE_ARRAY) {
        ++rank;
        t = t->elem;
    }
    return rank;
}

static int ir_contains_multidim_array(Type *t) {
    FieldList *f;
    if (is_error_type(t)) return 0;
    if (t->kind == TYPE_ARRAY) {
        if (ir_array_rank(t) > 1) return 1;
        return ir_contains_multidim_array(t->elem);
    }
    if (t->kind == TYPE_STRUCT) {
        for (f = t->fields; f; f = f->next) {
            if (ir_contains_multidim_array(f->type)) return 1;
        }
    }
    return 0;
}

static int ir_has_optional_4_2_feature(void) {
    Symbol *s;
    FieldList *p;
    for (s = symbol_table; s; s = s->next) {
        if (s->kind == SYM_VAR && ir_contains_multidim_array(s->type)) {
            return 1;
        }
        if (s->kind == SYM_FUNC && s->type && s->type->kind == TYPE_FUNCTION) {
            for (p = s->type->params; p; p = p->next) {
                if (p->type && p->type->kind == TYPE_ARRAY) return 1;
                if (ir_contains_multidim_array(p->type)) return 1;
            }
        }
    }
    return 0;
}

static int ir_field_offset(Type *st, const char *field_name, Type **field_type) {
    int offset = 0;
    FieldList *f;
    if (!st || st->kind != TYPE_STRUCT) return 0;
    for (f = st->fields; f; f = f->next) {
        if (f->name && strcmp(f->name, field_name) == 0) {
            if (field_type) *field_type = f->type;
            return offset;
        }
        offset += ir_type_size(f->type);
    }
    if (field_type) *field_type = type_error();
    return 0;
}

static Type *ir_exp_type(ASTNode *exp) {
    ExpInfo e = analyze_exp(exp);
    return e.type;
}

static int ir_exp_is_id(ASTNode *exp) {
    return exp && exp->child_count == 1 && exp->children[0]->type == NODE_ID;
}

static char *ir_exp_id_name(ASTNode *exp) {
    return exp->children[0]->str_val;
}

static char *ir_var_place(const char *src, Type *type, int is_param) {
    VarInfo *v = find_ir_var(src);
    if (!v) v = add_ir_var(src, type, is_param);
    return v->ir;
}

static char *ir_base_addr_from_var(const char *src) {
    VarInfo *v = find_ir_var(src);
    Type *t = ir_var_type(src);
    if (!v) v = add_ir_var(src, t, 0);
    if (v->is_param && ir_is_aggregate(v->type)) {
        /* Aggregate parameters are already passed by address. */
        return v->ir;
    } else {
        /*
         * Do not return a literal form like &v here.  The IR simulator accepts
         * &v in ARG and in arithmetic expressions, but using it under a star
         * (for example *&v := #1 or t := *&v) is not a reliable normalized
         * form.  All lvalue address computations therefore materialize the
         * address into a temporary first.
         */
        char *addr = new_temp();
        emit_ir("%s := &%s", addr, v->ir);
        return addr;
    }
}

static char *translate_exp(ASTNode *exp);
static void translate_cond(ASTNode *exp, const char *label_true, const char *label_false);
static AddrInfo translate_addr(ASTNode *exp);
static void translate_stmt(ASTNode *stmt);
static void translate_compst(ASTNode *compst);

static AddrInfo translate_addr(ASTNode *exp) {
    AddrInfo res;
    res.addr = ir_const(0);
    res.type = type_error();
    if (!exp) return res;

    if (ir_exp_is_id(exp)) {
        const char *name = ir_exp_id_name(exp);
        res.type = ir_var_type(name);
        res.addr = ir_base_addr_from_var(name);
        return res;
    }

    if (exp->child_count == 3 && exp->children[0]->type == NODE_LP) {
        return translate_addr(exp->children[1]);
    }

    if (exp->child_count == 4 && exp->children[1]->type == NODE_LB) {
        Type *arr_type = ir_exp_type(exp->children[0]);
        Type *elem_type = (!is_error_type(arr_type) && arr_type->kind == TYPE_ARRAY) ? arr_type->elem : type_error();
        AddrInfo base = translate_addr(exp->children[0]);
        char *idx = translate_exp(exp->children[2]);
        char *offset = new_temp();
        char *addr = new_temp();
        int elem_size = ir_type_size(elem_type);
        emit_ir("%s := %s * #%d", offset, idx, elem_size);
        emit_ir("%s := %s + %s", addr, base.addr, offset);
        res.addr = addr;
        res.type = elem_type;
        return res;
    }

    if (exp->child_count == 3 && exp->children[1]->type == NODE_DOT) {
        Type *field_type = type_error();
        AddrInfo base = translate_addr(exp->children[0]);
        int offset = ir_field_offset(base.type, exp->children[2]->str_val, &field_type);
        if (offset == 0) {
            res.addr = base.addr;
        } else {
            char *addr = new_temp();
            emit_ir("%s := %s + #%d", addr, base.addr, offset);
            res.addr = addr;
        }
        res.type = field_type;
        return res;
    }

    return res;
}

static char *translate_lvalue_read(ASTNode *exp) {
    AddrInfo a = translate_addr(exp);
    if (ir_is_aggregate(a.type)) return a.addr;
    {
        char *t = new_temp();
        emit_ir("%s := *%s", t, a.addr);
        return t;
    }
}

static char *translate_exp_as_arg(ASTNode *exp) {
    Type *t = ir_exp_type(exp);
    if (ir_is_aggregate(t)) {
        AddrInfo a = translate_addr(exp);
        return a.addr;
    }
    return translate_exp(exp);
}


static int ir_min_int(int a, int b) {
    return a < b ? a : b;
}

static void emit_ir_copy_memory(const char *dst_base, const char *src_base, int size) {
    int off;
    if (size <= 0) return;
    size = (size / 4) * 4;
    for (off = 0; off < size; off += 4) {
        char *src_addr;
        char *dst_addr;
        char *tmp = new_temp();
        if (off == 0) {
            src_addr = (char *)src_base;
            dst_addr = (char *)dst_base;
        } else {
            src_addr = new_temp();
            dst_addr = new_temp();
            emit_ir("%s := %s + #%d", src_addr, src_base, off);
            emit_ir("%s := %s + #%d", dst_addr, dst_base, off);
        }
        emit_ir("%s := *%s", tmp, src_addr);
        emit_ir("*%s := %s", dst_addr, tmp);
    }
}

static void collect_args(ASTNode *args, char **ops, int *count) {
    if (!args) return;
    ops[(*count)++] = translate_exp_as_arg(args->children[0]);
    if (args->child_count == 3) collect_args(args->children[2], ops, count);
}

static char *translate_call(ASTNode *exp) {
    ASTNode *id = exp->children[0];
    if (strcmp(id->str_val, "read") == 0 && exp->child_count == 3) {
        char *t = new_temp();
        emit_ir("READ %s", t);
        return t;
    }
    if (strcmp(id->str_val, "write") == 0 && exp->child_count == 4) {
        char *arg = translate_exp(exp->children[2]->children[0]);
        emit_ir("WRITE %s", arg);
        return ir_const(0);
    }
    {
        char *ops[256];
        int count = 0;
        int i;
        char *t = new_temp();
        if (exp->child_count == 4) collect_args(exp->children[2], ops, &count);
        for (i = count - 1; i >= 0; --i) emit_ir("ARG %s", ops[i]);
        emit_ir("%s := CALL %s", t, id->str_val);
        return t;
    }
}

static char *translate_exp(ASTNode *exp) {
    ASTNode *c0;
    if (!exp || exp->child_count == 0) return ir_const(0);
    c0 = exp->children[0];

    if (exp->child_count == 1) {
        if (c0->type == NODE_ID) {
            Type *t = ir_var_type(c0->str_val);
            char *place = ir_var_place(c0->str_val, t, 0);
            if (ir_is_aggregate(t)) return ir_base_addr_from_var(c0->str_val);
            return place;
        }
        if (c0->type == NODE_INT) return ir_const(c0->int_val);
        if (c0->type == NODE_FLOAT) {
            cannot_translate = 1;
            return ir_const(0);
        }
    }

    if (exp->child_count == 2) {
        if (c0->type == NODE_MINUS) {
            ASTNode *e = exp->children[1];
            if (e->child_count == 1 && e->children[0]->type == NODE_INT) {
                return ir_const(-e->children[0]->int_val);
            } else {
                char *x = translate_exp(e);
                char *t = new_temp();
                emit_ir("%s := #0 - %s", t, x);
                return t;
            }
        }
        if (c0->type == NODE_NOT) {
            char *t = new_temp();
            char *l1 = new_label();
            char *l2 = new_label();
            emit_ir("%s := #0", t);
            translate_cond(exp, l1, l2);
            emit_ir("LABEL %s :", l1);
            emit_ir("%s := #1", t);
            emit_ir("LABEL %s :", l2);
            return t;
        }
    }

    if (exp->child_count == 3 && exp->children[0]->type == NODE_LP) {
        return translate_exp(exp->children[1]);
    }

    if ((exp->child_count == 3 || exp->child_count == 4) &&
        exp->children[0]->type == NODE_ID && exp->children[1]->type == NODE_LP) {
        return translate_call(exp);
    }

    if (exp->child_count == 4 && exp->children[1]->type == NODE_LB) {
        return translate_lvalue_read(exp);
    }

    if (exp->child_count == 3 && exp->children[1]->type == NODE_DOT) {
        return translate_lvalue_read(exp);
    }

    if (exp->child_count == 3) {
        ASTNode *op = exp->children[1];
        if (op->type == NODE_ASSIGNOP) {
            Type *lhs_type = ir_exp_type(exp->children[0]);
            Type *rhs_type = ir_exp_type(exp->children[2]);
            char *rhs = translate_exp(exp->children[2]);
            if (ir_is_aggregate(lhs_type)) {
                AddrInfo a = translate_addr(exp->children[0]);
                int copy_size = ir_type_size(lhs_type);
                if (ir_is_aggregate(rhs_type)) copy_size = ir_min_int(copy_size, ir_type_size(rhs_type));
                emit_ir_copy_memory(a.addr, rhs, copy_size);
                return a.addr;
            }
            if (ir_exp_is_id(exp->children[0])) {
                const char *name = ir_exp_id_name(exp->children[0]);
                char *lhs = ir_var_place(name, ir_var_type(name), 0);
                emit_ir("%s := %s", lhs, rhs);
                return lhs;
            } else {
                AddrInfo a = translate_addr(exp->children[0]);
                emit_ir("*%s := %s", a.addr, rhs);
                return rhs;
            }
        }
        if (op->type == NODE_RELOP || op->type == NODE_AND || op->type == NODE_OR) {
            char *t = new_temp();
            char *l1 = new_label();
            char *l2 = new_label();
            emit_ir("%s := #0", t);
            translate_cond(exp, l1, l2);
            emit_ir("LABEL %s :", l1);
            emit_ir("%s := #1", t);
            emit_ir("LABEL %s :", l2);
            return t;
        }
        if (op->type == NODE_PLUS || op->type == NODE_MINUS || op->type == NODE_STAR || op->type == NODE_DIV) {
            char *x = translate_exp(exp->children[0]);
            char *y = translate_exp(exp->children[2]);
            char *t = new_temp();
            const char *sym = op->type == NODE_PLUS ? "+" : op->type == NODE_MINUS ? "-" : op->type == NODE_STAR ? "*" : "/";
            emit_ir("%s := %s %s %s", t, x, sym, y);
            return t;
        }
    }

    return ir_const(0);
}

static void translate_cond(ASTNode *exp, const char *label_true, const char *label_false) {
    if (!exp || exp->child_count == 0) {
        emit_ir("GOTO %s", label_false);
        return;
    }
    if (exp->child_count == 2 && exp->children[0]->type == NODE_NOT) {
        translate_cond(exp->children[1], label_false, label_true);
        return;
    }
    if (exp->child_count == 3 && exp->children[1]->type == NODE_AND) {
        char *l1 = new_label();
        translate_cond(exp->children[0], l1, label_false);
        emit_ir("LABEL %s :", l1);
        translate_cond(exp->children[2], label_true, label_false);
        return;
    }
    if (exp->child_count == 3 && exp->children[1]->type == NODE_OR) {
        char *l1 = new_label();
        translate_cond(exp->children[0], label_true, l1);
        emit_ir("LABEL %s :", l1);
        translate_cond(exp->children[2], label_true, label_false);
        return;
    }
    if (exp->child_count == 3 && exp->children[1]->type == NODE_RELOP) {
        char *x = translate_exp(exp->children[0]);
        char *y = translate_exp(exp->children[2]);
        emit_ir("IF %s %s %s GOTO %s", x, exp->children[1]->str_val, y, label_true);
        emit_ir("GOTO %s", label_false);
        return;
    }
    {
        char *x = translate_exp(exp);
        emit_ir("IF %s != #0 GOTO %s", x, label_true);
        emit_ir("GOTO %s", label_false);
    }
}

static void translate_declist(ASTNode *declist, Type *base) {
    while (declist) {
        ASTNode *dec = declist->children[0];
        ASTNode *vardec = dec->children[0];
        char *name = NULL;
        int line = vardec->line;
        Type *var_type = build_vardec_type(vardec, base, &name, &line);
        char *place = ir_var_place(name, var_type, 0);
        if (ir_is_aggregate(var_type)) {
            emit_ir("DEC %s %d", place, ir_type_size(var_type));
        }
        if (dec->child_count == 3) {
            char *rhs = translate_exp(dec->children[2]);
            if (!ir_is_aggregate(var_type)) emit_ir("%s := %s", place, rhs);
        }
        if (declist->child_count == 1) break;
        declist = declist->children[2];
    }
}

static void translate_deflist(ASTNode *deflist) {
    while (deflist) {
        ASTNode *def;
        Type *base;
        if (deflist->child_count < 1) break;
        def = deflist->children[0];
        if (!def || def->child_count < 2) {
            if (deflist->child_count == 1) break;
            deflist = deflist->children[1];
            continue;
        }
        base = analyze_specifier(def->children[0], 1);
        translate_declist(def->children[1], base);
        if (deflist->child_count == 1) break;
        deflist = deflist->children[1];
    }
}

static void translate_stmtlist(ASTNode *stmtlist) {
    while (stmtlist) {
        if (stmtlist->child_count < 1) break;
        translate_stmt(stmtlist->children[0]);
        if (stmtlist->child_count == 1) break;
        stmtlist = stmtlist->children[1];
    }
}

static void translate_compst(ASTNode *compst) {
    ASTNode *deflist;
    ASTNode *stmtlist;
    if (!compst) return;
    deflist = first_child(compst, NODE_DEFLIST);
    stmtlist = first_child(compst, NODE_STMTLIST);
    translate_deflist(deflist);
    translate_stmtlist(stmtlist);
}

static void translate_stmt(ASTNode *stmt) {
    if (!stmt || stmt->child_count == 0) return;
    if (stmt->child_count == 2 && stmt->children[1]->type == NODE_SEMI) {
        translate_exp(stmt->children[0]);
        return;
    }
    if (stmt->child_count == 1 && stmt->children[0]->type == NODE_COMPST) {
        translate_compst(stmt->children[0]);
        return;
    }
    if (stmt->child_count == 3 && stmt->children[0]->type == NODE_RETURN) {
        char *ret = translate_exp(stmt->children[1]);
        emit_ir("RETURN %s", ret);
        return;
    }
    if (stmt->children[0]->type == NODE_IF) {
        if (stmt->child_count == 5) {
            char *l1 = new_label();
            char *l2 = new_label();
            translate_cond(stmt->children[2], l1, l2);
            emit_ir("LABEL %s :", l1);
            translate_stmt(stmt->children[4]);
            emit_ir("LABEL %s :", l2);
        } else {
            char *l1 = new_label();
            char *l2 = new_label();
            char *l3 = new_label();
            translate_cond(stmt->children[2], l1, l2);
            emit_ir("LABEL %s :", l1);
            translate_stmt(stmt->children[4]);
            emit_ir("GOTO %s", l3);
            emit_ir("LABEL %s :", l2);
            translate_stmt(stmt->children[6]);
            emit_ir("LABEL %s :", l3);
        }
        return;
    }
    if (stmt->children[0]->type == NODE_WHILE) {
        char *l1 = new_label();
        char *l2 = new_label();
        char *l3 = new_label();
        emit_ir("LABEL %s :", l1);
        translate_cond(stmt->children[2], l2, l3);
        emit_ir("LABEL %s :", l2);
        translate_stmt(stmt->children[4]);
        emit_ir("GOTO %s", l1);
        emit_ir("LABEL %s :", l3);
        return;
    }
}

static void translate_paramdec(ASTNode *paramdec) {
    ASTNode *vardec = paramdec->children[1];
    char *name = NULL;
    int line = vardec->line;
    Type *type = ir_var_type("");
    Symbol *s;
    collect_vardec(vardec, &name, &line, (int[64]){0}, &(int){0});
    s = find_var_symbol(name);
    type = s ? s->type : type_error();
    emit_ir("PARAM %s", ir_var_place(name, type, 1));
}

static void translate_varlist(ASTNode *varlist) {
    while (varlist) {
        translate_paramdec(varlist->children[0]);
        if (varlist->child_count == 1) break;
        varlist = varlist->children[2];
    }
}

static void translate_fundec(ASTNode *fundec) {
    ASTNode *id = fundec->children[0];
    emit_ir("FUNCTION %s :", id->str_val);
    if (fundec->child_count == 4) translate_varlist(fundec->children[2]);
}

static void translate_extdef(ASTNode *extdef) {
    if (!extdef || extdef->child_count < 1) return;
    if (extdef->child_count >= 3 && extdef->children[1]->type == NODE_FUNDEC) {
        translate_fundec(extdef->children[1]);
        translate_compst(extdef->children[2]);
        return;
    }
    /* Lab 3 assumes no global variables are used. Struct definitions are intentionally ignored here. */
}

static void translate_extdeflist(ASTNode *list) {
    while (list) {
        if (list->child_count < 1) break;
        translate_extdef(list->children[0]);
        if (list->child_count == 1) break;
        list = list->children[1];
    }
}

void translate_ir(ASTNode *root_node, const char *out_path) {
    FILE *tmp;
    if (ir_has_optional_4_2_feature()) {
        fprintf(stderr, "Cannot translate: Code contains variables of multi-dimensional array type or parameters of array type.\n");
        return;
    }

    tmp = tmpfile();
    if (!tmp) {
        perror("tmpfile");
        return;
    }

    ir_out = tmp;
    ir_vars = NULL;
    temp_no = 1;
    label_no = 1;
    var_no = 1;
    cannot_translate = 0;

    if (root_node && root_node->child_count > 0) {
        translate_extdeflist(root_node->children[0]);
    }
    fflush(tmp);
    ir_out = NULL;

    if (cannot_translate) {
        fprintf(stderr, "Cannot translate: unsupported floating point value.\n");
        fclose(tmp);
        return;
    }

    generate_mips_from_ir(tmp, out_path);
    fclose(tmp);
}

}

%locations
%define parse.error verbose

%union {
    int int_val;
    double float_val;
    char *str;
    ASTNode *node;
}

%token <int_val> INT
%token <float_val> FLOAT
%token <str> ID
%token <str> TYPE
%token IF ELSE WHILE RETURN STRUCT
%token ASSIGNOP
%token <str> RELOP
%token AND OR NOT
%token PLUS MINUS STAR DIV
%token SEMI COMMA LP RP LC RC LB RB DOT

%type <node> Program ExtDefList ExtDef ExtDecList Specifier StructSpecifier
%type <node> FunDec CompSt DefList Def DecList Dec VarDec StmtList Stmt Exp Args
%type <node> VarList ParamDec OptTag Tag

%right ASSIGNOP
%left OR
%left AND
%left RELOP
%left PLUS MINUS
%left STAR DIV
%nonassoc UMINUS
%nonassoc NOT_HIGH
%left LB RB DOT
%nonassoc LOWER_THAN_ELSE
%nonassoc ELSE

%start Program

%%

Program
    : ExtDefList
      {
          $$ = new_node(NODE_PROGRAM, @1.first_line);
          add_child($$, $1);
          root = $$;
      }
    ;

ExtDefList
    : ExtDef ExtDefList
      {
          $$ = new_node(NODE_EXTDEFLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
      }
    | /* empty */
      {
          $$ = NULL;
      }
    ;

ExtDef
    : Specifier ExtDecList SEMI
      {
          $$ = new_node(NODE_EXTDEF, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
          add_child($$, new_node(NODE_SEMI, @3.first_line));
      }
    | Specifier FunDec CompSt
      {
          $$ = new_node(NODE_EXTDEF, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
          add_child($$, $3);
      }
    | Specifier SEMI
      {
          $$ = new_node(NODE_EXTDEF, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_SEMI, @2.first_line));
      }
    | error SEMI
      {
          $$ = NULL;
      }
    ;

ExtDecList
    : VarDec
      {
          $$ = new_node(NODE_EXTDECLIST, @1.first_line);
          add_child($$, $1);
      }
    | VarDec COMMA ExtDecList
      {
          $$ = new_node(NODE_EXTDECLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_COMMA, @2.first_line));
          add_child($$, $3);
      }
    ;

Specifier
    : TYPE
      {
          ASTNode *type_node = new_node(NODE_TYPE, @1.first_line);
          type_node->str_val = dupstr($1);
          $$ = new_node(NODE_SPECIFIER, @1.first_line);
          add_child($$, type_node);
      }
    | StructSpecifier
      {
          $$ = new_node(NODE_SPECIFIER, @1.first_line);
          add_child($$, $1);
      }
    ;

StructSpecifier
    : STRUCT OptTag LC DefList RC
      {
          $$ = new_node(NODE_STRUCTSPECIFIER, @1.first_line);
          add_child($$, new_node(NODE_STRUCT, @1.first_line));
          add_child($$, $2);
          add_child($$, new_node(NODE_LC, @3.first_line));
          add_child($$, $4);
          add_child($$, new_node(NODE_RC, @5.first_line));
      }
    | STRUCT Tag
      {
          $$ = new_node(NODE_STRUCTSPECIFIER, @1.first_line);
          add_child($$, new_node(NODE_STRUCT, @1.first_line));
          add_child($$, $2);
      }
    ;

OptTag
    : ID
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_OPTTAG, @1.first_line);
          add_child($$, id_node);
      }
    | /* empty */
      {
          $$ = new_node(NODE_OPTTAG, 0);
      }
    ;

Tag
    : ID
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_TAG, @1.first_line);
          add_child($$, id_node);
      }
    ;

FunDec
    : ID LP VarList RP
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_FUNDEC, @1.first_line);
          add_child($$, id_node);
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RP, @4.first_line));
      }
    | ID LP RP
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_FUNDEC, @1.first_line);
          add_child($$, id_node);
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, new_node(NODE_RP, @3.first_line));
      }
    ;

VarList
    : ParamDec COMMA VarList
      {
          $$ = new_node(NODE_VARLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_COMMA, @2.first_line));
          add_child($$, $3);
      }
    | ParamDec
      {
          $$ = new_node(NODE_VARLIST, @1.first_line);
          add_child($$, $1);
      }
    ;

ParamDec
    : Specifier VarDec
      {
          $$ = new_node(NODE_PARAMDEC, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
      }
    ;

CompSt
    : LC DefList StmtList RC
      {
          $$ = new_node(NODE_COMPST, @1.first_line);
          add_child($$, new_node(NODE_LC, @1.first_line));
          add_child($$, $2);
          add_child($$, $3);
          add_child($$, new_node(NODE_RC, @4.first_line));
      }
    ;

DefList
    : Def DefList
      {
          $$ = new_node(NODE_DEFLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
      }
    | /* empty */
      {
          $$ = NULL;
      }
    ;

Def
    : Specifier DecList SEMI
      {
          $$ = new_node(NODE_DEF, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
          add_child($$, new_node(NODE_SEMI, @3.first_line));
      }
    | error SEMI
      {
          $$ = NULL;
      }
    ;

DecList
    : Dec
      {
          $$ = new_node(NODE_DECLIST, @1.first_line);
          add_child($$, $1);
      }
    | Dec COMMA DecList
      {
          $$ = new_node(NODE_DECLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_COMMA, @2.first_line));
          add_child($$, $3);
      }
    ;

Dec
    : VarDec
      {
          $$ = new_node(NODE_DEC, @1.first_line);
          add_child($$, $1);
      }
    | VarDec ASSIGNOP Exp
      {
          $$ = new_node(NODE_DEC, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_ASSIGNOP, @2.first_line));
          add_child($$, $3);
      }
    ;

VarDec
    : ID
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_VARDEC, @1.first_line);
          add_child($$, id_node);
      }
    | VarDec LB INT RB
      {
          ASTNode *int_node = new_node(NODE_INT, @3.first_line);
          int_node->int_val = $3;
          $$ = new_node(NODE_VARDEC, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_LB, @2.first_line));
          add_child($$, int_node);
          add_child($$, new_node(NODE_RB, @4.first_line));
      }
    ;

StmtList
    : Stmt StmtList
      {
          $$ = new_node(NODE_STMTLIST, @1.first_line);
          add_child($$, $1);
          add_child($$, $2);
      }
    | /* empty */
      {
          $$ = NULL;
      }
    ;

Stmt
    : Exp SEMI
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_SEMI, @2.first_line));
      }
    | CompSt
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, $1);
      }
    | RETURN Exp SEMI
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, new_node(NODE_RETURN, @1.first_line));
          add_child($$, $2);
          add_child($$, new_node(NODE_SEMI, @3.first_line));
      }
    | IF LP Exp RP Stmt %prec LOWER_THAN_ELSE
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, new_node(NODE_IF, @1.first_line));
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RP, @4.first_line));
          add_child($$, $5);
      }
    | IF LP Exp RP Stmt ELSE Stmt
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, new_node(NODE_IF, @1.first_line));
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RP, @4.first_line));
          add_child($$, $5);
          add_child($$, new_node(NODE_ELSE, @6.first_line));
          add_child($$, $7);
      }
    | WHILE LP Exp RP Stmt
      {
          $$ = new_node(NODE_STMT, @1.first_line);
          add_child($$, new_node(NODE_WHILE, @1.first_line));
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RP, @4.first_line));
          add_child($$, $5);
      }
    | error SEMI
      {
          $$ = NULL;
      }
    ;

Exp
    : Exp ASSIGNOP Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_ASSIGNOP, @2.first_line));
          add_child($$, $3);
      }
    | Exp AND Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_AND, @2.first_line));
          add_child($$, $3);
      }
    | Exp OR Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_OR, @2.first_line));
          add_child($$, $3);
      }
    | Exp RELOP Exp
      {
          ASTNode *relop = new_node(NODE_RELOP, @2.first_line);
          relop->str_val = dupstr($2);
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, relop);
          add_child($$, $3);
      }
    | Exp PLUS Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_PLUS, @2.first_line));
          add_child($$, $3);
      }
    | Exp MINUS Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_MINUS, @2.first_line));
          add_child($$, $3);
      }
    | Exp STAR Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_STAR, @2.first_line));
          add_child($$, $3);
      }
    | Exp DIV Exp
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_DIV, @2.first_line));
          add_child($$, $3);
      }
    | LP Exp RP
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, new_node(NODE_LP, @1.first_line));
          add_child($$, $2);
          add_child($$, new_node(NODE_RP, @3.first_line));
      }
    | MINUS Exp %prec UMINUS
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, new_node(NODE_MINUS, @1.first_line));
          add_child($$, $2);
      }
    | NOT Exp %prec NOT_HIGH
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, new_node(NODE_NOT, @1.first_line));
          add_child($$, $2);
      }
    | ID LP Args RP
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, id_node);
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RP, @4.first_line));
      }
    | ID LP RP
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, id_node);
          add_child($$, new_node(NODE_LP, @2.first_line));
          add_child($$, new_node(NODE_RP, @3.first_line));
      }
    | Exp LB Exp RB
      {
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_LB, @2.first_line));
          add_child($$, $3);
          add_child($$, new_node(NODE_RB, @4.first_line));
      }
    | Exp DOT ID
      {
          ASTNode *id_node = new_node(NODE_ID, @3.first_line);
          id_node->str_val = dupstr($3);
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_DOT, @2.first_line));
          add_child($$, id_node);
      }
    | ID
      {
          ASTNode *id_node = new_node(NODE_ID, @1.first_line);
          id_node->str_val = dupstr($1);
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, id_node);
      }
    | INT
      {
          ASTNode *int_node = new_node(NODE_INT, @1.first_line);
          int_node->int_val = $1;
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, int_node);
      }
    | FLOAT
      {
          ASTNode *float_node = new_node(NODE_FLOAT, @1.first_line);
          float_node->float_val = $1;
          $$ = new_node(NODE_EXP, @1.first_line);
          add_child($$, float_node);
      }
    ;

Args
    : Exp COMMA Args
      {
          $$ = new_node(NODE_ARGS, @1.first_line);
          add_child($$, $1);
          add_child($$, new_node(NODE_COMMA, @2.first_line));
          add_child($$, $3);
      }
    | Exp
      {
          $$ = new_node(NODE_ARGS, @1.first_line);
          add_child($$, $1);
      }
    ;

%%

ASTNode *new_node(NodeType type, int line) {
    ASTNode *node = (ASTNode *)malloc(sizeof(ASTNode));
    if (!node) exit(1);
    node->type = type;
    node->line = line;
    node->str_val = NULL;
    node->int_val = 0;
    node->float_val = 0.0;
    node->children = NULL;
    node->child_count = 0;
    node->child_capacity = 0;
    return node;
}

void add_child(ASTNode *parent, ASTNode *child) {
    if (parent == NULL || child == NULL) return;
    if (parent->child_count == parent->child_capacity) {
        int new_cap = parent->child_capacity == 0 ? 4 : parent->child_capacity * 2;
        ASTNode **new_children = (ASTNode **)realloc(parent->children, sizeof(ASTNode *) * new_cap);
        if (!new_children) exit(1);
        parent->children = new_children;
        parent->child_capacity = new_cap;
    }
    parent->children[parent->child_count++] = child;
}

void free_ast(ASTNode *node) {
    int i;
    if (!node) return;
    for (i = 0; i < node->child_count; ++i) free_ast(node->children[i]);
    free(node->str_val);
    free(node->children);
    free(node);
}

void yyerror(const char *msg) {
    (void)msg;
    if (lexer_error_just_happened) {
        lexer_error_just_happened = 0;
        return;
    }
    has_error = 1;
    printf("Error type B at Line %d: syntax error.\n", yylineno);
}
