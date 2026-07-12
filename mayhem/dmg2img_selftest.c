/*
 * dmg2img_selftest.c — behavioral known-answer unit oracle for dmg2img's codecs.
 *
 * dmg2img ships NO upstream test suite, so this asserts the authors' code produces exact known
 * outputs for adc_decompress() (adc.c) and decode_base64()/cleanup_base64() (base64.c). A patch
 * that breaks either codec — or a neutered exit(0) binary — makes these assertions fail. Prints a
 * `PASS name` / `FAIL name` line per test; mayhem/test.sh parses these into a CTRF summary.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "adc.h"
#include "base64.h"

static int g_pass, g_fail;

static void check(const char *name, int ok)
{
	if (ok) { g_pass++; printf("PASS %s\n", name); }
	else    { g_fail++; printf("FAIL %s\n", name); }
}

/* ADC: a leading byte with bit7 set is an ADC_PLAIN chunk of (byte&0x7f)+1 literal bytes. */
static void test_adc_plain(void)
{
	unsigned char in[] = { 0x82, 'A', 'B', 'C' }; /* PLAIN, size 3 -> "ABC" */
	unsigned char out[64];
	int written = 0;
	int consumed = adc_decompress(sizeof(in), in, sizeof(out), out, &written);
	check("adc_plain_written", written == 3);
	check("adc_plain_bytes", memcmp(out, "ABC", 3) == 0);
	check("adc_plain_consumed", consumed == 4);
}

/* ADC: a 2-byte back-reference chunk copies previously-written output. */
static void test_adc_backref(void)
{
	/* PLAIN "AB" (0x81,'A','B') then 2-byte chunk: type byte 0x00..0x3f => ADC_2BYTE,
	 * length = ((b>>2)&0x0f)+3, offset = ((b&3)<<8 | next)+1. b=0x04 -> len=4, next=0x01 -> off=2.
	 * Copies 4 bytes from 2 behind the write head over "AB" -> "ABABAB.." */
	unsigned char in[] = { 0x81, 'A', 'B', 0x04, 0x01 };
	unsigned char out[64];
	int written = 0;
	adc_decompress(sizeof(in), in, sizeof(out), out, &written);
	check("adc_backref_written", written == 6);
	check("adc_backref_bytes", memcmp(out, "ABABAB", 6) == 0);
}

static void test_adc_chunk_helpers(void)
{
	check("adc_chunk_type_plain", adc_chunk_type(0x82) == ADC_PLAIN);
	check("adc_chunk_type_2byte", adc_chunk_type(0x10) == ADC_2BYTE);
	check("adc_chunk_type_3byte", adc_chunk_type(0x40) == ADC_3BYTE);
	check("adc_chunk_size_plain", adc_chunk_size(0x82) == 3);
}

/* base64: dmg2img decodes IN PLACE (inp == out). "TWFu" -> "Man". */
static void test_base64(void)
{
	char buf[16];
	unsigned int osize = 0;
	strcpy(buf, "TWFu");
	decode_base64(buf, 4, buf, &osize);
	check("base64_size", osize == 3);
	check("base64_bytes", memcmp(buf, "Man", 3) == 0);

	char buf2[16];
	unsigned int o2 = 0;
	strcpy(buf2, "aGk=");   /* "hi" */
	decode_base64(buf2, 4, buf2, &o2);
	check("base64_pad_size", o2 == 2);
	check("base64_pad_bytes", memcmp(buf2, "hi", 2) == 0);
}

static void test_cleanup_base64(void)
{
	char buf[32];
	strcpy(buf, "TW\nFu ==");           /* whitespace stripped, base64 chars kept */
	cleanup_base64(buf, (unsigned)strlen(buf));
	check("cleanup_base64", strcmp(buf, "TWFu==") == 0);
}

int main(void)
{
	test_adc_plain();
	test_adc_backref();
	test_adc_chunk_helpers();
	test_base64();
	test_cleanup_base64();
	printf("SELFTEST pass=%d fail=%d\n", g_pass, g_fail);
	return g_fail ? 1 : 0;
}
