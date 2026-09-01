#include <stdio.h>
#include <stdlib.h>
#include "syntax.tab.h"

extern ASTNode *root;
extern int has_error;
extern FILE *yyin;
int yyparse(void);

int main(int argc, char **argv) {
    FILE *f;
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <filename>\n", argv[0]);
        return 1;
    }

    f = fopen(argv[1], "r");
    if (f == NULL) {
        perror(argv[1]);
        return 1;
    }

    yyin = f;
    yyparse();
    fclose(f);

    if (!has_error && root != NULL) {
        analyze_semantics(root);
    }

    if (root != NULL) {
        free_ast(root);
    }

    return 0;
}
