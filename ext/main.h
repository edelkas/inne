#ifndef INNE
#define INNE

#include <stdbool.h>
#include "ruby.h"

/* Entry point */
void Init_cinne();

/* Library functions */
VALUE c_stb_sha1(VALUE self, VALUE data);

/* STB functions */
bool stb_sha1(unsigned char output[20], unsigned char *buffer, unsigned int len);

#endif