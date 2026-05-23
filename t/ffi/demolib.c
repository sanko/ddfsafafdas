#include <stdio.h>

int add(int a, int b) { return a + b; }

void hello(const char* name) { printf("Hello, %s from C!\n", name); fflush(stdout); }

// Force the C runtime stdout stream to be unbuffered so that C's puts/printf
// output flushes immediately and synchronizes perfectly with Brocken's direct system calls.
#ifdef __GNUC__
__attribute__((constructor)) void init_unbuffered() {
    setvbuf(stdout, NULL, _IONBF, 0);
}
#endif
