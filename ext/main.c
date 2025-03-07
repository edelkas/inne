#include "main.h"

/*
 * Entry point of the library.
 * This function gets called when it gets required in Ruby
 */
void Init_cinne() {
  rb_define_global_const("C_INNE", LONG2FIX(1));
  rb_define_global_function("c_stb_sha1", c_stb_sha1, 1);
}

/*
 * SHA1-encode a binary string using STB's implementation.
 * This is the exact implementation used by N++, and it differs from Ruby's one
 * sometimes. This way, we ensure perfect security hash computation.
 */
VALUE c_stb_sha1(VALUE self, VALUE data) {
  if (!RB_TYPE_P(data, T_STRING))
    rb_raise(rb_eRuntimeError, "No data to SHA1 encode.");
  unsigned char* buf = (unsigned char*)RSTRING_PTR(data);
  long len = RSTRING_LEN(data);
  unsigned char hash[20];
  bool success = stb_sha1(hash, buf, len);
  return success ? rb_str_new((const char*)hash, 20) : Qnil;
}