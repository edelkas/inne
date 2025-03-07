// This code is directly taken (and slightly modified) from the great STB:
// https://github.com/nothings/stb/

#include <stdlib.h>
#include <stdbool.h>

#define stb_big32(c) (((c)[0]<<24) + (c)[1]*65536 + (c)[2]*256 + (c)[3])

static void stb__sha1(unsigned char *chunk, unsigned int h[5])
{
   int i;
   unsigned int a,b,c,d,e;
   unsigned int w[80];

   for (i=0; i < 16; ++i)
      w[i] = stb_big32(&chunk[i*4]);
   for (i=16; i < 80; ++i) {
      unsigned int t;
      t = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
      w[i] = (t + t) | (t >> 31);
   }

   a = h[0];
   b = h[1];
   c = h[2];
   d = h[3];
   e = h[4];

   #define STB__SHA1(k,f)                                            \
   {                                                                 \
      unsigned int temp = (a << 5) + (a >> 27) + (f) + e + (k) + w[i];  \
      e = d;                                                       \
      d = c;                                                     \
      c = (b << 30) + (b >> 2);                               \
      b = a;                                              \
      a = temp;                                    \
   }

   i=0;
   for (; i < 20; ++i) STB__SHA1(0x5a827999, d ^ (b & (c ^ d))       );
   for (; i < 40; ++i) STB__SHA1(0x6ed9eba1, b ^ c ^ d               );
   for (; i < 60; ++i) STB__SHA1(0x8f1bbcdc, (b & c) + (d & (b ^ c)) );
   for (; i < 80; ++i) STB__SHA1(0xca62c1d6, b ^ c ^ d               );

   #undef STB__SHA1

   h[0] += a;
   h[1] += b;
   h[2] += c;
   h[3] += d;
   h[4] += e;
}

bool stb_sha1(unsigned char output[20], unsigned char *buffer, unsigned int len)
{
   unsigned char final_block[128];
   unsigned int end_start, final_len, j;
   int i;

   unsigned int h[5];

   h[0] = 0x67452301;
   h[1] = 0xefcdab89;
   h[2] = 0x98badcfe;
   h[3] = 0x10325476;
   h[4] = 0xc3d2e1f0;

   end_start = len & ~63;

   if (((len+9) & ~63) == end_start) {
      end_start -= 64;
   }

   final_len = end_start + 128;

   if (!(end_start + 128 >= len+9) || !(end_start < len || len < 64-9))
      return false;

   j = 0;
   if (end_start > len)
      j = (unsigned int) - (int) end_start;

   for (; end_start + j < len; ++j)
      final_block[j] = buffer[end_start + j];
   final_block[j++] = 0x80;
   while (j < 128-5)
      final_block[j++] = 0;

   final_block[j++] = len >> 29;
   final_block[j++] = len >> 21;
   final_block[j++] = len >> 13;
   final_block[j++] = len >>  5;
   final_block[j++] = len <<  3;
   if (!(j == 128 && end_start + j == final_len))
      return false;

   for (j=0; j < final_len; j += 64) {
      if (j+64 >= end_start+64)
         stb__sha1(&final_block[j - end_start], h);
      else
         stb__sha1(&buffer[j], h);
   }

   for (i=0; i < 5; ++i) {
      output[i*4 + 0] = h[i] >> 24;
      output[i*4 + 1] = h[i] >> 16;
      output[i*4 + 2] = h[i] >>  8;
      output[i*4 + 3] = h[i] >>  0;
   }

   return true;
}