#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
    char *copy = malloc(64);
    strcpy(copy, "heap works");
    printf("printf from 32-bit x86: %s, sizeof(void*)=%u, argc=%d, 6*7=%d\n", copy, (unsigned)sizeof(void*), argc, 6*7);
    return 0;
}
