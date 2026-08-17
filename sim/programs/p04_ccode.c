/* p04_ccode -- compiled C, which is a different program from hand-written
 * assembly in the ways that matter here.
 *
 * A compiler emits things a person writing tests does not think to: MOVEM
 * prologues sized to whatever the register allocator wanted, frame pointers,
 * PC-relative loads of constants, jump tables out of switch statements, and
 * calls into the helpers for the arithmetic the instruction set does not
 * have -- which on an MC68010 is every 32-bit multiply and divide, and which
 * sim/programs/libmc68010.S supplies, because the libgcc that ships with the
 * toolchain is built for a 68020 and contains instructions this part has
 * never had.
 *
 * So this is not a test of C. It is a test of the instruction sequences gcc
 * chooses when nobody is watching, run at -Os.
 *
 * Each check returns its own number on failure and the crt0 turns that into
 * the mark the harness reads.
 */

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;
typedef signed short   s16;
typedef signed long    s32;

static volatile int check_no;

#define CHECK(n)     do { check_no = (n); PROGRESS = (u32)(n); } while (0)
#define EXPECT(cond) do { if (!(cond)) return check_no; } while (0)

/* Every input below goes through here first.
 *
 * Without it gcc folds the whole program: the inputs are constants, so at -Os
 * it computes every answer at compile time and main becomes five instructions
 * that write the progress word and return. That is a test of gcc's constant
 * folder and of nothing else. Pushing each value through a register the
 * compiler cannot see into makes it emit the arithmetic instead -- which is
 * the point, since the arithmetic is what is being tested. */
static inline u32 opaque(u32 v)
{
    __asm__ volatile ("" : "+d" (v));
    return v;
}

static inline const void *opaquep(const void *p)
{
    __asm__ volatile ("" : "+a" (p));
    return p;
}

/* The word sim/programs/link.ld puts at 0x0404, reached through the barrier
 * above so that gcc does not warn about an array at address zero. */
#define PROGRESS (*(volatile u32 *)opaque(0x0404))

/* gcc emits calls to these for structure copies and array initialisation even
 * with -ffreestanding, so a freestanding program has to bring its own. */
void *memcpy(void *d, const void *s, unsigned long n)
{
    u8 *dp = d;
    const u8 *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, unsigned long n)
{
    u8 *dp = d;
    while (n--) *dp++ = (u8)c;
    return d;
}

/* ------------------------------------------------------------------ */

struct thing {
    u16 id;
    u8  flags;
    u8  pad;
    u32 value;
};

static struct thing things[6];
static u32 table[8];
static char buf[32];

static u32 crc32_table[256];

static void crc32_init(void)
{
    u32 i, j, c;
    for (i = 0; i < opaque(256); i++) {
        c = i;
        for (j = 0; j < 8; j++)
            c = (c & 1) ? (0xEDB88320UL ^ (c >> 1)) : (c >> 1);
        crc32_table[i] = c;
    }
}

static u32 crc32(const void *pv, u32 n)
{
    const u8 *p = pv;
    u32 c = 0xFFFFFFFFUL;
    while (n--)
        c = crc32_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFUL;
}

static u32 fnv1a(const void *sv)
{
    const char *s = sv;
    u32 h = 2166136261UL;
    while (*s) {
        h ^= (u8)*s++;
        h *= 16777619UL;            /* a 32-bit multiply: libgcc's */
    }
    return h;
}

static void sort_things(struct thing *t, int n)
{
    int i, j;
    struct thing tmp;
    for (i = 0; i < n - 1; i++)
        for (j = 0; j < n - 1 - i; j++)
            if (t[j].value > t[j + 1].value) {
                tmp      = t[j];
                t[j]     = t[j + 1];
                t[j + 1] = tmp;
            }
}

static int classify(int n)
{
    switch (n) {                    /* a jump table, if gcc feels like it */
    case 0:  return 100;
    case 1:  return 101;
    case 2:  return 102;
    case 3:  return 103;
    case 4:  return 104;
    case 5:  return 105;
    case 6:  return 106;
    case 7:  return 107;
    default: return -1;
    }
}

static u32 ackermannish(u32 m, u32 n)
{
    if (m == 0) return n + 1;
    if (n == 0) return ackermannish(m - 1, 1);
    return ackermannish(m - 1, ackermannish(m, n - 1));
}

static int add(int a, int b)  { return a + b; }
static int mul(int a, int b)  { return a * b; }
static int sub(int a, int b)  { return a - b; }

static int (*const ops[3])(int, int) = { add, mul, sub };

int main(void)
{
    u32 i, c;
    s32 a, b;
    const char *msg = "the quick brown fox";

    /* -------------------------------------------------------------- */
    CHECK(1);                       /* 32-bit multiply and divide: libgcc */
    /* -------------------------------------------------------------- */
    a = (s32)opaque(123456);
    b = (s32)opaque(789);
    EXPECT(a * b == 97406784L);
    EXPECT(a / b == 156L);
    EXPECT(a % b == 372L);
    a = (s32)opaque((u32)-123456L);
    EXPECT(a / b == -156L);
    EXPECT(a % b == -372L);

    /* -------------------------------------------------------------- */
    CHECK(2);                       /* the same helpers, worked harder */
    /* -------------------------------------------------------------- */
    /* Long long is left out on purpose: it would need __muldi3 and the
     * shift helpers as well, and sim/programs/libmc68010.S is meant to be
     * the few a C program cannot do without rather than a libgcc. */
    c = 0;
    for (i = 1; i <= opaque(50); i++)
        c += (0x01000000UL / i) ^ (i * opaque(2654435761UL));
    EXPECT(c == 0xFFE248A2UL);

    /* -------------------------------------------------------------- */
    CHECK(3);                       /* sign extension across widths */
    /* -------------------------------------------------------------- */
    {
        signed char sc = (signed char)opaque((u32)-3L);
        s16 sh = (s16)opaque((u32)-300L);
        EXPECT((s32)sc == -3L);
        EXPECT((s32)sh == -300L);
        EXPECT((u32)(u8)sc == 253UL);
        EXPECT((u32)(u16)sh == 65236UL);
    }

    /* -------------------------------------------------------------- */
    CHECK(4);                       /* an array, a loop, and a sum */
    /* -------------------------------------------------------------- */
    for (i = 0; i < opaque(8); i++) table[i] = i * i * opaque(7) + 1;
    c = 0;
    for (i = 0; i < opaque(8); i++) c += table[i];
    EXPECT(c == 8UL + 7UL * (0+1+4+9+16+25+36+49));

    /* -------------------------------------------------------------- */
    CHECK(5);                       /* structs: copies, and a sort of them */
    /* -------------------------------------------------------------- */
    for (i = 0; i < opaque(6); i++) {
        things[i].id    = (u16)(i + 1);
        things[i].flags = (u8)(0x80 | i);
        things[i].value = (u32)((6 - i) * opaque(1000) + i);
    }
    sort_things(things, (int)opaque(6));
    for (i = 1; i < 6; i++)
        EXPECT(things[i - 1].value < things[i].value);
    EXPECT(things[0].id == 6);      /* the smallest value was the last one */
    EXPECT(things[5].id == 1);
    EXPECT(things[0].flags == (0x80 | 5));

    /* -------------------------------------------------------------- */
    CHECK(6);                       /* a switch, and everything it misses */
    /* -------------------------------------------------------------- */
    for (i = 0; i < opaque(8); i++)
        EXPECT(classify((int)opaque(i)) == (int)(100 + i));
    EXPECT(classify((int)opaque(8)) == -1);
    EXPECT(classify((int)opaque((u32)-1L)) == -1);

    /* -------------------------------------------------------------- */
    CHECK(7);                       /* bytes, and a string the hard way */
    /* -------------------------------------------------------------- */
    {
        const char *s = opaquep(msg);
        char *d = buf;
        u32 n = 0;
        while (*s) { *d++ = *s++; n++; }
        *d = '\0';
        EXPECT(n == 19UL);
        EXPECT(buf[0] == 't' && buf[18] == 'x' && buf[19] == '\0');
    }

    /* -------------------------------------------------------------- */
    CHECK(8);                       /* a table-driven CRC over the lot */
    /* -------------------------------------------------------------- */
    crc32_init();
    EXPECT(crc32_table[opaque(1)] == 0x77073096UL);
    EXPECT(crc32_table[opaque(255)] == 0x2D02EF8DUL);
    c = crc32(opaquep("123456789"), opaque(9));
    EXPECT(c == 0xCBF43926UL);      /* the standard check value */

    /* -------------------------------------------------------------- */
    CHECK(9);                       /* a hash, which is multiplies in a loop */
    /* -------------------------------------------------------------- */
    EXPECT(fnv1a(opaquep("")) == 2166136261UL);
    EXPECT(fnv1a(opaquep("a")) == 0xE40C292CUL);
    EXPECT(fnv1a(opaquep("foobar")) == 0xBF9CF968UL);

    /* -------------------------------------------------------------- */
    CHECK(10);                      /* recursion deep enough to matter */
    /* -------------------------------------------------------------- */
    EXPECT(ackermannish(opaque(2), opaque(3)) == 9UL);
    EXPECT(ackermannish(opaque(3), opaque(2)) == 29UL);

    /* -------------------------------------------------------------- */
    CHECK(11);                      /* calls through a table of pointers */
    /* -------------------------------------------------------------- */
    EXPECT(ops[opaque(0)]((int)opaque(7), (int)opaque(5)) == 12);
    EXPECT(ops[opaque(1)]((int)opaque(7), (int)opaque(5)) == 35);
    EXPECT(ops[opaque(2)]((int)opaque(7), (int)opaque(5)) == 2);
    {
        int acc = (int)opaque(1);
        for (i = 0; i < opaque(3); i++) acc = ops[i](acc, 3);
        EXPECT(acc == 9);           /* ((1+3)*3)-3 */
    }

    /* -------------------------------------------------------------- */
    CHECK(12);                      /* shifts, at every width and both ways */
    /* -------------------------------------------------------------- */
    {
        u32 v = opaque(0x12345678UL);
        EXPECT((v << 4) == 0x23456780UL);
        EXPECT((v >> 4) == 0x01234567UL);
        EXPECT(((s32)opaque(0x80000000UL) >> 4) == (s32)0xF8000000UL);
        EXPECT((u32)((u16)opaque(0x8000UL) >> 4) == 0x0800UL);
        for (i = 0, c = 1; i < opaque(31); i++) c <<= 1;
        EXPECT(c == 0x80000000UL);
    }

    return 0;
}
