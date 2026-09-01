%code requires {
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    NODE_PROGRAM, NODE_EXTDEFLIST, NODE_EXTDEF, NODE_EXTDECLIST,
    NODE_SPECIFIER, NODE_STRUCTSPECIFIER,
    NODE_FUNDEC, NODE_COMPST, NODE_DEFLIST, NODE_DEF, NODE_DECLIST, NODE_DEC,
    NODE_VARDEC, NODE_STMTLIST, NODE_STMT, NODE_EXP, NODE_ARGS,
    NODE_TYPE, NODE_ID, NODE_INT, NODE_FLOAT,
    NODE_RELOP, NODE_ASSIGNOP, NODE_AND, NODE_OR, NODE_PLUS, NODE_MINUS,
    NODE_STAR, NODE_DIV, NODE_IF, NODE_ELSE, NODE_WHILE, NODE_RETURN,
    NODE_STRUCT, NODE_DOT,
    NODE_LP, NODE_RP, NODE_LC, NODE_RC, NODE_SEMI, NODE_COMMA,
    NODE_LB, NODE_RB, NODE_VARLIST, NODE_PARAMDEC,
    NODE_OPTTAG, NODE_TAG, NODE_NOT
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
void print_ast(ASTNode *node, int indent);
void free_ast(ASTNode *node);

extern int yylineno;
extern int yylex(void);
void yyerror(const char *msg);
}

%code {
ASTNode *root;
int has_error = 0;
extern int lexer_error_just_happened;
#include "lex.yy.c"
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
%type <node> VarList ParamDec

%right ASSIGNOP
%left OR
%left AND
%left RELOP
%left PLUS MINUS
%left STAR DIV
%nonassoc UMINUS
%nonassoc NOT_HIGH
%left LB RB
%nonassoc LOWER_THAN_ELSE
%nonassoc ELSE

%start Program

%%

Program : ExtDefList {
    $$ = new_node(NODE_PROGRAM, @1.first_line);
    add_child($$, $1);
    root = $$;
}

ExtDefList : ExtDef ExtDefList {
    $$ = new_node(NODE_EXTDEFLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
}
| /* empty */ { $$ = NULL; }

ExtDef : Specifier ExtDecList SEMI {
    $$ = new_node(NODE_EXTDEF, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
    add_child($$, new_node(NODE_SEMI, @3.first_line));
}
| Specifier FunDec CompSt {
    $$ = new_node(NODE_EXTDEF, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
    add_child($$, $3);
}
| Specifier SEMI {
    $$ = new_node(NODE_EXTDEF, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_SEMI, @2.first_line));
}
| error SEMI { $$ = NULL; }
;

ExtDecList : VarDec {
    $$ = new_node(NODE_EXTDECLIST, @1.first_line);
    add_child($$, $1);
}
| VarDec COMMA ExtDecList {
    $$ = new_node(NODE_EXTDECLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_COMMA, @2.first_line));
    add_child($$, $3);
}
;

Specifier : TYPE {
    $$ = new_node(NODE_SPECIFIER, @1.first_line);
    ASTNode *type_node = new_node(NODE_TYPE, @1.first_line);
    type_node->str_val = strdup($1);
    add_child($$, type_node);
}
| StructSpecifier {
    $$ = new_node(NODE_SPECIFIER, @1.first_line);
    add_child($$, $1);
}
;

StructSpecifier : STRUCT ID {
    $$ = new_node(NODE_STRUCTSPECIFIER, @$.first_line);
    add_child($$, new_node(NODE_STRUCT, @1.first_line));
    ASTNode *tag_node = new_node(NODE_TAG, @2.first_line);
    ASTNode *id_node = new_node(NODE_ID, @2.first_line);
    id_node->str_val = strdup($2);
    add_child(tag_node, id_node);
    add_child($$, tag_node);
}
| STRUCT ID LC DefList RC {
    $$ = new_node(NODE_STRUCTSPECIFIER, @$.first_line);
    add_child($$, new_node(NODE_STRUCT, @1.first_line));
    ASTNode *opt_tag_node = new_node(NODE_OPTTAG, @2.first_line);
    ASTNode *id_node = new_node(NODE_ID, @2.first_line);
    id_node->str_val = strdup($2);
    add_child(opt_tag_node, id_node);
    add_child($$, opt_tag_node);
    add_child($$, new_node(NODE_LC, @3.first_line));
    add_child($$, $4);
    add_child($$, new_node(NODE_RC, @5.first_line));
}
;

FunDec : ID LP VarList RP {
    $$ = new_node(NODE_FUNDEC, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RP, @4.first_line));
}
| ID LP RP {
    $$ = new_node(NODE_FUNDEC, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, new_node(NODE_RP, @3.first_line));
}
;

VarList : ParamDec COMMA VarList {
    $$ = new_node(NODE_VARLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_COMMA, @2.first_line));
    add_child($$, $3);
}
| ParamDec {
    $$ = new_node(NODE_VARLIST, @1.first_line);
    add_child($$, $1);
}
;

ParamDec : Specifier VarDec {
    $$ = new_node(NODE_PARAMDEC, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
}
;

CompSt : LC DefList StmtList RC {
    $$ = new_node(NODE_COMPST, @1.first_line);
    add_child($$, new_node(NODE_LC, @1.first_line));
    add_child($$, $2);
    add_child($$, $3);
    add_child($$, new_node(NODE_RC, @4.first_line));
}
;

DefList : Def DefList {
    $$ = new_node(NODE_DEFLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
}
| /* empty */ { $$ = NULL; }
;

Def : Specifier DecList SEMI {
    $$ = new_node(NODE_DEF, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
    add_child($$, new_node(NODE_SEMI, @3.first_line));
}
| error SEMI { $$ = NULL; }
;

DecList : Dec {
    $$ = new_node(NODE_DECLIST, @1.first_line);
    add_child($$, $1);
}
| Dec COMMA DecList {
    $$ = new_node(NODE_DECLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_COMMA, @2.first_line));
    add_child($$, $3);
}
;

Dec : VarDec {
    $$ = new_node(NODE_DEC, @1.first_line);
    add_child($$, $1);
}
| VarDec ASSIGNOP Exp {
    $$ = new_node(NODE_DEC, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_ASSIGNOP, @2.first_line));
    add_child($$, $3);
}
;

VarDec : ID {
    $$ = new_node(NODE_VARDEC, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
}
| VarDec LB INT RB {
    $$ = new_node(NODE_VARDEC, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_LB, @2.first_line));
    ASTNode *int_node = new_node(NODE_INT, @3.first_line);
    int_node->int_val = $3;
    add_child($$, int_node);
    add_child($$, new_node(NODE_RB, @4.first_line));
}
;

StmtList : Stmt StmtList {
    $$ = new_node(NODE_STMTLIST, @1.first_line);
    add_child($$, $1);
    add_child($$, $2);
}
| /* empty */ { $$ = NULL; }
;

Stmt : Exp SEMI {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_SEMI, @2.first_line));
}
| CompSt {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, $1);
}
| RETURN Exp SEMI {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, new_node(NODE_RETURN, @1.first_line));
    add_child($$, $2);
    add_child($$, new_node(NODE_SEMI, @3.first_line));
}
| RETURN error SEMI {
    $$ = NULL;
}
| IF LP Exp RP Stmt %prec LOWER_THAN_ELSE {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, new_node(NODE_IF, @1.first_line));
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RP, @4.first_line));
    add_child($$, $5);
}
| IF LP error RP Stmt %prec LOWER_THAN_ELSE {
    $$ = NULL;
}
| IF LP Exp RP Stmt ELSE Stmt {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, new_node(NODE_IF, @1.first_line));
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RP, @4.first_line));
    add_child($$, $5);
    add_child($$, new_node(NODE_ELSE, @6.first_line));
    add_child($$, $7);
}
| IF LP error RP Stmt ELSE Stmt {
    $$ = NULL;
}
| WHILE LP Exp RP Stmt {
    $$ = new_node(NODE_STMT, @1.first_line);
    add_child($$, new_node(NODE_WHILE, @1.first_line));
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RP, @4.first_line));
    add_child($$, $5);
}
| WHILE LP error RP Stmt {
    $$ = NULL;
}
| error SEMI {
    $$ = NULL;
}
;

Exp : MINUS Exp %prec UMINUS {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, new_node(NODE_MINUS, @1.first_line));
    add_child($$, $2);
}
| NOT Exp %prec NOT_HIGH {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, new_node(NODE_NOT, @1.first_line));
    add_child($$, $2);
}
| Exp ASSIGNOP Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_ASSIGNOP, @2.first_line));
    add_child($$, $3);
}
| Exp AND Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_AND, @2.first_line));
    add_child($$, $3);
}
| Exp OR Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_OR, @2.first_line));
    add_child($$, $3);
}
| Exp RELOP Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    ASTNode *relop_node = new_node(NODE_RELOP, @2.first_line);
    relop_node->str_val = strdup($2);
    add_child($$, relop_node);
    add_child($$, $3);
}
| Exp PLUS Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_PLUS, @2.first_line));
    add_child($$, $3);
}
| Exp MINUS Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_MINUS, @2.first_line));
    add_child($$, $3);
}
| Exp STAR Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_STAR, @2.first_line));
    add_child($$, $3);
}
| Exp DIV Exp {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_DIV, @2.first_line));
    add_child($$, $3);
}
| LP Exp RP {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, new_node(NODE_LP, @1.first_line));
    add_child($$, $2);
    add_child($$, new_node(NODE_RP, @3.first_line));
}
| Exp LB Exp RB {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_LB, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RB, @4.first_line));
}
| ID {
    $$ = new_node(NODE_EXP, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
}
| INT {
    $$ = new_node(NODE_EXP, @1.first_line);
    ASTNode *int_node = new_node(NODE_INT, @1.first_line);
    int_node->int_val = $1;
    add_child($$, int_node);
}
| FLOAT {
    $$ = new_node(NODE_EXP, @1.first_line);
    ASTNode *float_node = new_node(NODE_FLOAT, @1.first_line);
    float_node->float_val = $1;
    add_child($$, float_node);
}
| ID LP Args RP {
    $$ = new_node(NODE_EXP, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, $3);
    add_child($$, new_node(NODE_RP, @4.first_line));
}
| ID LP RP {
    $$ = new_node(NODE_EXP, @1.first_line);
    ASTNode *id_node = new_node(NODE_ID, @1.first_line);
    id_node->str_val = strdup($1);
    add_child($$, id_node);
    add_child($$, new_node(NODE_LP, @2.first_line));
    add_child($$, new_node(NODE_RP, @3.first_line));
}
| Exp DOT ID {
    $$ = new_node(NODE_EXP, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_DOT, @2.first_line));
    ASTNode *id_node = new_node(NODE_ID, @3.first_line);
    id_node->str_val = strdup($3);
    add_child($$, id_node);
}
;

Args : Exp COMMA Args {
    $$ = new_node(NODE_ARGS, @1.first_line);
    add_child($$, $1);
    add_child($$, new_node(NODE_COMMA, @2.first_line));
    add_child($$, $3);
}
| Exp {
    $$ = new_node(NODE_ARGS, @1.first_line);
    add_child($$, $1);
}
;

%%

ASTNode *new_node(NodeType type, int line) {
    ASTNode *node = (ASTNode *)malloc(sizeof(ASTNode));
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
    if (child == NULL) return;
    if (parent->child_count == parent->child_capacity) {
        parent->child_capacity = parent->child_capacity == 0 ? 4 : parent->child_capacity * 2;
        parent->children = (ASTNode **)realloc(parent->children, parent->child_capacity * sizeof(ASTNode *));
    }
    parent->children[parent->child_count++] = child;
}

void print_ast(ASTNode *node, int indent) {
    if (node == NULL) return;
    for (int i = 0; i < indent; ++i) printf("  ");
    switch (node->type) {
        case NODE_PROGRAM: printf("Program"); break;
        case NODE_EXTDEFLIST: printf("ExtDefList"); break;
        case NODE_EXTDEF: printf("ExtDef"); break;
        case NODE_EXTDECLIST: printf("ExtDecList"); break;
        case NODE_SPECIFIER: printf("Specifier"); break;
        case NODE_STRUCTSPECIFIER: printf("StructSpecifier"); break;
        case NODE_FUNDEC: printf("FunDec"); break;
        case NODE_COMPST: printf("CompSt"); break;
        case NODE_DEFLIST: printf("DefList"); break;
        case NODE_DEF: printf("Def"); break;
        case NODE_DECLIST: printf("DecList"); break;
        case NODE_DEC: printf("Dec"); break;
        case NODE_VARDEC: printf("VarDec"); break;
        case NODE_STMTLIST: printf("StmtList"); break;
        case NODE_STMT: printf("Stmt"); break;
        case NODE_EXP: printf("Exp"); break;
        case NODE_ARGS: printf("Args"); break;
        case NODE_TYPE: printf("TYPE: %s", node->str_val); break;
        case NODE_ID: printf("ID: %s", node->str_val); break;
        case NODE_INT: printf("INT: %d", node->int_val); break;
        case NODE_FLOAT: printf("FLOAT: %f", node->float_val); break;
        case NODE_RELOP: printf("RELOP"); break;
        case NODE_ASSIGNOP: printf("ASSIGNOP"); break;
        case NODE_AND: printf("AND"); break;
        case NODE_OR: printf("OR"); break;
        case NODE_PLUS: printf("PLUS"); break;
        case NODE_MINUS: printf("MINUS"); break;
        case NODE_STAR: printf("STAR"); break;
        case NODE_DIV: printf("DIV"); break;
        case NODE_IF: printf("IF"); break;
        case NODE_ELSE: printf("ELSE"); break;
        case NODE_WHILE: printf("WHILE"); break;
        case NODE_RETURN: printf("RETURN"); break;
        case NODE_STRUCT: printf("STRUCT"); break;
        case NODE_DOT: printf("DOT"); break;
        case NODE_LP: printf("LP"); break;
        case NODE_RP: printf("RP"); break;
        case NODE_LC: printf("LC"); break;
        case NODE_RC: printf("RC"); break;
        case NODE_SEMI: printf("SEMI"); break;
        case NODE_COMMA: printf("COMMA"); break;
        case NODE_LB: printf("LB"); break;
        case NODE_RB: printf("RB"); break;
        case NODE_VARLIST: printf("VarList"); break;
        case NODE_PARAMDEC: printf("ParamDec"); break;
        case NODE_OPTTAG: printf("OptTag"); break;
        case NODE_TAG: printf("Tag"); break;
        case NODE_NOT: printf("NOT"); break;
        default: printf("Unknown"); break;
    }
    int is_terminal = (node->type == NODE_ID || node->type == NODE_INT || node->type == NODE_FLOAT ||
                       node->type == NODE_TYPE || node->type == NODE_ASSIGNOP || node->type == NODE_AND ||
                       node->type == NODE_OR || node->type == NODE_PLUS || node->type == NODE_MINUS ||
                       node->type == NODE_STAR || node->type == NODE_DIV || node->type == NODE_RELOP ||
                       node->type == NODE_IF || node->type == NODE_ELSE || node->type == NODE_WHILE ||
                       node->type == NODE_RETURN || node->type == NODE_STRUCT || node->type == NODE_DOT ||
                       node->type == NODE_LP || node->type == NODE_RP || node->type == NODE_LC ||
                       node->type == NODE_RC || node->type == NODE_SEMI || node->type == NODE_COMMA ||
                       node->type == NODE_LB || node->type == NODE_RB || node->type == NODE_NOT);
    if (!is_terminal && node->line > 0) {
        printf(" (%d)", node->line);
    }
    printf("\n");
    for (int i = 0; i < node->child_count; ++i) {
        print_ast(node->children[i], indent + 1);
    }
}

void free_ast(ASTNode *node) {
    if (node == NULL) return;
    for (int i = 0; i < node->child_count; ++i) free_ast(node->children[i]);
    if (node->str_val) free(node->str_val);
    free(node->children);
    free(node);
}

void yyerror(const char *msg) {
    if (lexer_error_just_happened) {
        lexer_error_just_happened = 0;
        return;
    }
    has_error = 1;
    printf("Error type B at Line %d : syntax error.\n", yylineno);
}
