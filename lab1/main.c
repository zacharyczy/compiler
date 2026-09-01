#include <stdio.h>
#include <stdlib.h>
#include "syntax.tab.h"

extern ASTNode *root;
extern int has_error;
extern FILE *yyin;
int yyparse();

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
        return 1;
    }
    FILE *f = fopen(argv[1], "r");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    yyin = f;
    yyparse();
    fclose(f);
    if (!has_error && root) {
        print_ast(root, 0);
        free_ast(root);
    }
    return 0;
}
