#include <stdio.h>
#include "optimizer.h"

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input.ir> <output.ir>\n", argv[0]);
        return 1;
    }
    return optimize_ir_file(argv[1], argv[2]);
}
