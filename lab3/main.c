#include <stdio.h>
#include <stdlib.h>
#include "syntax.tab.h"

extern ASTNode *root;
extern int has_error;
extern FILE *yyin;
int yyparse(void);

int main(int argc, char **argv) {
    FILE *f;
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input.cmm> <output.ir>\n", argv[0]);
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

    if (!has_error && root != NULL) {
        translate_ir(root, argv[2]);
    }

    if (root != NULL) {
        free_ast(root);
    }

    return has_error ? 1 : 0;
}
