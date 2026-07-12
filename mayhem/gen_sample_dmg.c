/*
 * gen_sample_dmg.c — materialize a minimal, structurally-valid DMG whose single BT_RAW block
 * copies a known payload verbatim. Used by mayhem/test.sh as an end-to-end known-answer oracle:
 * `dmg2img sample.dmg out.img` must reproduce exactly `sample.expected`.
 *
 * This is a build-time fixture generator (not shipped as a binary blob) so the oracle stays
 * reproducible and air-gapped. It writes big-endian fields at the exact offsets dmg2img reads
 * (koly trailer @ last 512 bytes; XML plist with a base64 `mish` block table).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char PAYLOAD[] =
    "dmg2img end-to-end oracle payload: 0123456789ABCDEF the quick brown fox.";

static void put_be32(unsigned char *p, uint32_t v)
{
	p[0] = (v >> 24) & 0xff; p[1] = (v >> 16) & 0xff;
	p[2] = (v >> 8) & 0xff;  p[3] = v & 0xff;
}
static void put_be64(unsigned char *p, uint64_t v)
{
	put_be32(p, (uint32_t)(v >> 32));
	put_be32(p + 4, (uint32_t)(v & 0xffffffffu));
}

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* standard base64 encode */
static size_t b64_encode(const unsigned char *in, size_t n, char *out)
{
	size_t o = 0, i;
	for (i = 0; i + 2 < n; i += 3) {
		uint32_t x = (in[i] << 16) | (in[i + 1] << 8) | in[i + 2];
		out[o++] = B64[(x >> 18) & 0x3f];
		out[o++] = B64[(x >> 12) & 0x3f];
		out[o++] = B64[(x >> 6) & 0x3f];
		out[o++] = B64[x & 0x3f];
	}
	if (n - i == 1) {
		uint32_t x = in[i] << 16;
		out[o++] = B64[(x >> 18) & 0x3f];
		out[o++] = B64[(x >> 12) & 0x3f];
		out[o++] = '=';
		out[o++] = '=';
	} else if (n - i == 2) {
		uint32_t x = (in[i] << 16) | (in[i + 1] << 8);
		out[o++] = B64[(x >> 18) & 0x3f];
		out[o++] = B64[(x >> 12) & 0x3f];
		out[o++] = B64[(x >> 6) & 0x3f];
		out[o++] = '=';
	}
	out[o] = '\0';
	return o;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <out.dmg> <out.expected>\n", argv[0]);
		return 2;
	}
	const size_t L = sizeof(PAYLOAD) - 1;         /* payload length */
	const uint64_t sectors = (L + 0x1ff) / 0x200; /* sectorCount */

	/* --- mishblk blob: 0xCC header + 2 run entries (BT_RAW, BT_TERM) --- */
	const size_t RUNS = 2;
	const size_t blob_len = 0xCC + RUNS * 0x28;
	unsigned char blob[0xCC + 2 * 0x28];
	memset(blob, 0, sizeof(blob));
	memcpy(blob, "mish", 4);         /* BlocksSignature (read big-endian -> 0x6D697368) */
	put_be32(blob + 0xC8, RUNS);     /* BlocksRunCount */

	unsigned char *r0 = blob + 0xCC; /* run 0: BT_RAW */
	put_be32(r0 + 0, 0x00000001);    /* block_type = BT_RAW */
	put_be64(r0 + 8, 0);             /* sectorStart */
	put_be64(r0 + 16, sectors);      /* sectorCount */
	put_be64(r0 + 24, 0);            /* in_offs (relative to DataForkOffset) */
	put_be64(r0 + 32, L);            /* in_size */

	unsigned char *r1 = blob + 0xCC + 0x28; /* run 1: BT_TERM */
	put_be32(r1 + 0, 0xffffffff);

	char b64[4 * ((0xCC + 2 * 0x28) / 3) + 8];
	b64_encode(blob, blob_len, b64);

	/* --- XML property list --- */
	char plist[4096];
	int xn = snprintf(plist, sizeof(plist),
		"<plist version=\"1.0\">\n"
		"<dict>\n"
		"\t<key>blkx</key>\n"
		"\t<array>\n"
		"\t<dict>\n"
		"\t\t<key>Data</key>\n"
		"\t\t<data>%s</data>\n"
		"\t\t<key>Name</key>\n"
		"\t\t<string>part0</string>\n"
		"\t</dict>\n"
		"\t</array>\n"
		"</dict>\n"
		"</plist>\n",
		b64);
	if (xn < 0 || (size_t)xn >= sizeof(plist)) {
		fprintf(stderr, "plist overflow\n");
		return 1;
	}
	const uint64_t xml_off = L;
	const uint64_t xml_len = (uint64_t)xn;

	/* --- koly trailer (512 bytes) --- */
	unsigned char koly[0x200];
	memset(koly, 0, sizeof(koly));
	memcpy(koly, "koly", 4);           /* Signature */
	put_be32(koly + 4, 4);             /* Version */
	put_be32(koly + 8, 0x200);         /* HeaderSize */
	put_be64(koly + 24, 0);            /* DataForkOffset */
	put_be64(koly + 32, L);            /* DataForkLength */
	put_be64(koly + 40, 0);            /* RsrcForkOffset (0 -> use XML path) */
	put_be64(koly + 48, 0);            /* RsrcForkLength */
	put_be64(koly + 216, xml_off);     /* XMLOffset */
	put_be64(koly + 224, xml_len);     /* XMLLength */
	put_be64(koly + 492, sectors);     /* SectorCount */

	/* --- write file: payload | plist | koly --- */
	FILE *f = fopen(argv[1], "wb");
	if (!f) { perror("fopen dmg"); return 1; }
	fwrite(PAYLOAD, 1, L, f);
	fwrite(plist, 1, xml_len, f);
	fwrite(koly, 1, sizeof(koly), f);
	fclose(f);

	FILE *e = fopen(argv[2], "wb");
	if (!e) { perror("fopen expected"); return 1; }
	fwrite(PAYLOAD, 1, L, e);
	fclose(e);

	printf("gen_sample_dmg: wrote %s (%zu payload bytes)\n", argv[1], L);
	return 0;
}
