#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
typedef int (*fetch_t)(const unsigned char*, int64_t, uint64_t*, int64_t*, int32_t*);
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    fetch_t f = (fetch_t)dlsym(h, "goosenet_fetch");
    uint64_t p = 0; int64_t len = 0; int32_t status = 0;
    struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
    int rc = f((const unsigned char*)argv[2], (int64_t)strlen(argv[2]), &p, &len, &status);
    clock_gettime(CLOCK_MONOTONIC, &b);
    printf("rc=%d status=%d len=%lld seconds=%.1f\n", rc, status, (long long)len,
           (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9);
    return 0;
}
