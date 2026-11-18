/*
 * dozchat — a member of a Dozable chat room, for an agent inside Dozable: one static program, libc and POSIX only.
 *
 * Dozable puts it in every sandbox (/usr/local/lib/doz/bin/dozchat, linked as /usr/local/bin/dozchat when that name is
 * free) and on every fenced session's PATH on the Mac (the session's own shim). It speaks the chat protocol
 * (docs/chat/protocol.md) as a participant that polls, with the commands and exit codes of docs/chat/client/chat_client.py:
 *
 *     dozchat rooms [--room ROOM]
 *     dozchat send ROOM TEXT... [--re MSG_ID] [--to NAME ...] [--dm]       TEXT "-" reads it from stdin (at most 1 MiB);
 *                                                                          several words are joined with one space; the
 *                                                                          options go before or after the text
 *     dozchat react ROOM MSG_ID REACTION
 *     dozchat receive [--wait SECONDS] [--ack] [--redeliver]
 *     dozchat ack ROOM:MSG_ID[:DELIVERY] ...                              or: ack -   (reads receive's lines)
 *     dozchat listen [--wait SECONDS] [--once]
 *     dozchat file get URL-OR-ID [--out FOLDER] [--name NAME]
 *     dozchat file send ROOM PATH [TEXT] [--re MSG_ID]
 *     dozchat protocol [--room ROOM]
 *
 * Configuration, from the environment only (nothing secret on the command line, ever):
 *     CHAT_URL          http://HOST[:PORT] — no user, path or query; default http://host.dozable.internal:8790, and on a
 *                       Mac with no proxy set (a session run without a fence) http://127.0.0.1:8790
 *     CHAT_TOKEN_FILE   a regular file of this user that no one else may read or write (not a link), at most 4 KiB
 *     CHAT_TOKEN        the token itself, used only when CHAT_TOKEN_FILE is not set
 *     http_proxy, then HTTP_PROXY: an http:// proxy (its password is sent as Proxy-Authorization: Basic); NO_PROXY /
 *     no_proxy: exact host names, or *
 *
 * Exit codes: 0 done · 1 a local problem, or a bad or unexpected answer (a 3xx too) · 2 usage or configuration ·
 * 3 refused (422; the answer is printed) · 4 401, 403 or 409 · 5 no answer, a timeout, or a 5xx · 130 interrupted.
 *
 * The rules this file keeps (each has a test in test/unit-check.c or the Swift suites):
 *   - No JSON parser: request bodies are literal text plus json_str(), the strict escaper; an answer is printed with the
 *     whitespace outside its strings removed; a bounded scanner (depth 64) finds only the `messages` array, the ids an
 *     acknowledgement needs, and `error` / `detail`.
 *   - Every buffer has a hard maximum; every size computation is checked; no strcpy, sprintf, strcat or gets; every
 *     format string is a literal.
 *   - The token and the proxy's password are never printed, never in an error, never on a command line, and zeroed
 *     before the program ends. Words for a person (stderr) are scrubbed of both.
 *   - Plain HTTP/1.1 only, one connection per call, `Connection: close`: no TLS, no redirect followed, no chunked
 *     encoding (any Transfer-Encoding is a broken answer), one Content-Length at most, a deadline on every call.
 *   - `file get` writes only with openat(the folder, the cleaned name, O_CREAT|O_EXCL|O_NOFOLLOW) after the whole file
 *     is in memory, and removes a partial file.
 *
 * Its own version (DOZCHAT_VERSION) is not Dozable's: the guest binary's bytes change only when this file does.
 */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _DEFAULT_SOURCE 1
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/random.h>
#endif

#define DOZCHAT_VERSION "2"
#define DEFAULT_URL "http://host.dozable.internal:8790"
/* On a Mac with no proxy set — a session run on the Mac without a fence, where the chat server is this Mac's own — the
 * default is this Mac's loopback. A fenced session always has its proxy set (and no DNS), so it keeps DEFAULT_URL. */
#define MAC_DIRECT_URL "http://127.0.0.1:8790"

#define KIB ((size_t)1024)
#define MIB (KIB * KIB)
#define MAX_ANSWER (32 * MIB + 64 * KIB) /* the server's line limit plus a head */
#define MAX_REQUEST_BODY (32 * MIB)
#define MAX_HEAD (64 * KIB)
#define MAX_HEADER_LINE (8 * KIB)
#define MAX_FILE (20 * MIB)
#define MAX_STDIN_TEXT MIB
#define MAX_ACK_LINE (32 * MIB)
#define MAX_TOKEN_FILE 4096
#define MAX_ID 256
#define MAX_DEPTH 64
#define MAX_TYPE 255
#define MAX_REASON 300

#define CONNECT_TIMEOUT 10
#define CALL_TIMEOUT 30
#define FILE_TIMEOUT 120

enum { EXIT_DONE = 0, EXIT_LOCAL = 1, EXIT_USAGE = 2, EXIT_REFUSED = 3, EXIT_DENIED = 4, EXIT_AWAY = 5 };

/* ---------------------------------------------------------------------------------------------------------------
 * Secrets: zeroed with a store the compiler cannot drop; scrubbed out of every word for a person.
 * ------------------------------------------------------------------------------------------------------------ */

static void wipe(void *p, size_t n) {
    volatile unsigned char *v = (volatile unsigned char *)p;
    while (n--) *v++ = 0;
}

static char g_token[MAX_TOKEN_FILE + 1];
static size_t g_token_len;
static char g_proxy_secret[1024]; /* the proxy URL's password, decoded */
static size_t g_proxy_secret_len;
static char g_proxy_auth[2048]; /* base64(user:password) */
static size_t g_proxy_auth_len;

static void wipe_secrets(void) {
    wipe(g_token, sizeof g_token);
    wipe(g_proxy_secret, sizeof g_proxy_secret);
    wipe(g_proxy_auth, sizeof g_proxy_auth);
    g_token_len = g_proxy_secret_len = g_proxy_auth_len = 0;
}

static void on_interrupt(int sig) {
    (void)sig;
    wipe_secrets();
    _exit(130);
}

/* Where `needle` (n bytes) starts in `hay` (h bytes), or SIZE_MAX. */
static size_t find_bytes(const unsigned char *hay, size_t h, const unsigned char *needle, size_t n) {
    if (n == 0 || n > h) return SIZE_MAX;
    for (size_t i = 0; i + n <= h; i++)
        if (hay[i] == needle[0] && memcmp(hay + i, needle, n) == 0) return i;
    return SIZE_MAX;
}

/* ---------------------------------------------------------------------------------------------------------------
 * struct buf: a growable buffer with a hard maximum. Growth copies and zeroes the old block (it may hold a secret).
 * ------------------------------------------------------------------------------------------------------------ */

struct buf {
    unsigned char *p;
    size_t len, cap, max;
};

static struct buf buf_new(size_t max) {
    struct buf b = {NULL, 0, 0, max};
    return b;
}

static void buf_free(struct buf *b) {
    if (b->p) {
        wipe(b->p, b->cap);
        free(b->p);
    }
    b->p = NULL;
    b->len = b->cap = 0;
}

/* Room for `add` more bytes, or -1 (past the maximum, or out of memory). */
static int buf_reserve(struct buf *b, size_t add) {
    if (add > b->max || b->len > b->max - add) return -1;
    size_t need = b->len + add;
    if (need <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < need) {
        if (nc > SIZE_MAX / 2) { nc = need; break; }
        nc *= 2;
    }
    if (nc > b->max) nc = b->max;
    if (nc < need) return -1;
    unsigned char *q = malloc(nc);
    if (!q) return -1;
    if (b->p) {
        if (b->len) memcpy(q, b->p, b->len);
        wipe(b->p, b->cap);
        free(b->p);
    }
    b->p = q;
    b->cap = nc;
    return 0;
}

static int buf_add(struct buf *b, const void *d, size_t n) {
    if (n == 0) return 0;
    if (buf_reserve(b, n) < 0) return -1;
    memcpy(b->p + b->len, d, n);
    b->len += n;
    return 0;
}

static int buf_addc(struct buf *b, unsigned char c) { return buf_add(b, &c, 1); }
static int buf_adds(struct buf *b, const char *s) { return buf_add(b, s, strlen(s)); }

static int buf_addu(struct buf *b, unsigned long long v) {
    char d[24];
    size_t i = sizeof d;
    do { d[--i] = (char)('0' + (v % 10)); v /= 10; } while (v && i > 0);
    return buf_add(b, d + i, sizeof d - i);
}

/* ---------------------------------------------------------------------------------------------------------------
 * UTF-8 and the escaper: request bodies are built only from literal text and json_str().
 * ------------------------------------------------------------------------------------------------------------ */

/* The length of the well-formed UTF-8 sequence at s (n bytes left), or 0: overlong forms, surrogates, anything above
 * U+10FFFF, a lone continuation byte and a cut sequence are all refused. */
static size_t utf8_seq(const unsigned char *s, size_t n) {
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    if (c >= 0xC2 && c <= 0xDF) return (n >= 2 && (s[1] & 0xC0) == 0x80) ? 2 : 0;
    if (c >= 0xE0 && c <= 0xEF) {
        if (n < 3) return 0;
        unsigned char lo = 0x80, hi = 0xBF;
        if (c == 0xE0) lo = 0xA0;
        if (c == 0xED) hi = 0x9F;
        return (s[1] >= lo && s[1] <= hi && (s[2] & 0xC0) == 0x80) ? 3 : 0;
    }
    if (c >= 0xF0 && c <= 0xF4) {
        if (n < 4) return 0;
        unsigned char lo = 0x80, hi = 0xBF;
        if (c == 0xF0) lo = 0x90;
        if (c == 0xF4) hi = 0x8F;
        return (s[1] >= lo && s[1] <= hi && (s[2] & 0xC0) == 0x80 && (s[3] & 0xC0) == 0x80) ? 4 : 0;
    }
    return 0;
}

enum { ESC_OK = 0, ESC_INVALID = -1, ESC_TOO_BIG = -2 };

/* Append s (n bytes) as a JSON string, quotes included. */
static int json_str(struct buf *out, const unsigned char *s, size_t n) {
    static const char hex[] = "0123456789abcdef";
    if (buf_addc(out, '"') < 0) return ESC_TOO_BIG;
    size_t i = 0;
    while (i < n) {
        size_t k = utf8_seq(s + i, n - i);
        if (!k) return ESC_INVALID;
        unsigned char c = s[i];
        int r = 0;
        if (k > 1) r = buf_add(out, s + i, k);
        else if (c == '"') r = buf_adds(out, "\\\"");
        else if (c == '\\') r = buf_adds(out, "\\\\");
        else if (c == '\n') r = buf_adds(out, "\\n");
        else if (c == '\r') r = buf_adds(out, "\\r");
        else if (c == '\t') r = buf_adds(out, "\\t");
        else if (c < 0x20 || c == 0x7F) {
            unsigned char e[6] = {'\\', 'u', '0', '0', (unsigned char)hex[c >> 4], (unsigned char)hex[c & 15]};
            r = buf_add(out, e, sizeof e);
        } else r = buf_addc(out, c);
        if (r < 0) return ESC_TOO_BIG;
        i += k;
    }
    return buf_addc(out, '"') < 0 ? ESC_TOO_BIG : ESC_OK;
}

static int json_strz(struct buf *out, const char *s) { return json_str(out, (const unsigned char *)s, strlen(s)); }

/* ---------------------------------------------------------------------------------------------------------------
 * The bounded scanner — not a JSON parser. It walks one value at a time (depth at most 64), keeping track of strings
 * and escapes, and refuses an unclosed string, a control character inside one, a bad escape and unbalanced brackets.
 * ------------------------------------------------------------------------------------------------------------ */

static size_t skip_ws(const unsigned char *s, size_t n, size_t i) {
    while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
    return i;
}

static int is_hex(unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

static unsigned hex_val(unsigned char c) {
    return c <= '9' ? (unsigned)(c - '0') : (c >= 'a' ? (unsigned)(c - 'a' + 10) : (unsigned)(c - 'A' + 10));
}

/* s[i] is '"': *end becomes the index after the closing quote. */
static int scan_string(const unsigned char *s, size_t n, size_t i, size_t *end) {
    i++;
    while (i < n) {
        unsigned char c = s[i];
        if (c == '"') { *end = i + 1; return 0; }
        if (c < 0x20) return -1;
        if (c == '\\') {
            if (i + 1 >= n) return -1;
            unsigned char e = s[i + 1];
            if (e == 'u') {
                if (n - i < 6) return -1;
                for (size_t k = 2; k < 6; k++)
                    if (!is_hex(s[i + k])) return -1;
                i += 6;
                continue;
            }
            if (!strchr("\"\\/bfnrt", e) || e == 0) return -1;
            i += 2;
            continue;
        }
        i++;
    }
    return -1;
}

static int scan_value(const unsigned char *s, size_t n, size_t i, int depth, size_t *end);

static int scan_container(const unsigned char *s, size_t n, size_t i, int depth, size_t *end) {
    unsigned char close = s[i] == '{' ? '}' : ']';
    int object = s[i] == '{';
    if (depth >= MAX_DEPTH) return -1;
    i = skip_ws(s, n, i + 1);
    if (i < n && s[i] == close) { *end = i + 1; return 0; }
    for (;;) {
        size_t e;
        if (object) {
            if (i >= n || s[i] != '"' || scan_string(s, n, i, &e) < 0) return -1;
            i = skip_ws(s, n, e);
            if (i >= n || s[i] != ':') return -1;
            i = skip_ws(s, n, i + 1);
        }
        if (scan_value(s, n, i, depth + 1, &e) < 0) return -1;
        i = skip_ws(s, n, e);
        if (i >= n) return -1;
        if (s[i] == close) { *end = i + 1; return 0; }
        if (s[i] != ',') return -1;
        i = skip_ws(s, n, i + 1);
    }
}

/* One value at s[i] (no leading whitespace): *end is the index after it. */
static int scan_value(const unsigned char *s, size_t n, size_t i, int depth, size_t *end) {
    if (i >= n) return -1;
    unsigned char c = s[i];
    if (c == '"') return scan_string(s, n, i, end);
    if (c == '{' || c == '[') return scan_container(s, n, i, depth, end);
    static const char *const words[] = {"true", "false", "null"};
    for (size_t w = 0; w < 3; w++) {
        size_t l = strlen(words[w]);
        if (n - i >= l && memcmp(s + i, words[w], l) == 0) { *end = i + l; return 0; }
    }
    size_t j = i;
    while (j < n && (s[j] == '-' || s[j] == '+' || s[j] == '.' || s[j] == 'e' || s[j] == 'E' || (s[j] >= '0' && s[j] <= '9'))) j++;
    if (j == i) return -1;
    *end = j;
    return 0;
}

/* The one value s holds (whitespace around it allowed): its range. */
static int scan_document(const unsigned char *s, size_t n, size_t *start, size_t *end) {
    size_t i = skip_ws(s, n, 0), e;
    if (scan_value(s, n, i, 0, &e) < 0) return -1;
    if (skip_ws(s, n, e) != n) return -1;
    *start = i;
    *end = e;
    return 0;
}

/* The value s[a..b) (already scanned) with every whitespace byte outside its strings removed. */
static int json_compact(struct buf *out, const unsigned char *s, size_t a, size_t b) {
    int in_str = 0, esc = 0;
    for (size_t i = a; i < b; i++) {
        unsigned char c = s[i];
        if (in_str) {
            if (esc) esc = 0;
            else if (c == '\\') esc = 1;
            else if (c == '"') in_str = 0;
        } else {
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
            if (c == '"') in_str = 1;
        }
        if (buf_addc(out, c) < 0) return -1;
    }
    return 0;
}

static int put_utf8(struct buf *out, unsigned long cp) {
    unsigned char u[4];
    size_t k;
    if (cp < 0x80) { u[0] = (unsigned char)cp; k = 1; }
    else if (cp < 0x800) { u[0] = (unsigned char)(0xC0 | (cp >> 6)); u[1] = (unsigned char)(0x80 | (cp & 0x3F)); k = 2; }
    else if (cp < 0x10000) {
        u[0] = (unsigned char)(0xE0 | (cp >> 12)); u[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        u[2] = (unsigned char)(0x80 | (cp & 0x3F)); k = 3;
    } else {
        u[0] = (unsigned char)(0xF0 | (cp >> 18)); u[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        u[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F)); u[3] = (unsigned char)(0x80 | (cp & 0x3F)); k = 4;
    }
    return buf_add(out, u, k);
}

/* Decode the string s[a..b) (quotes included, already scanned) into out: every escape, surrogate pairs as UTF-8. A lone
 * surrogate is refused. */
static int json_decode_string(struct buf *out, const unsigned char *s, size_t a, size_t b) {
    if (b < a + 2 || s[a] != '"' || s[b - 1] != '"') return -1;
    size_t i = a + 1, end = b - 1;
    while (i < end) {
        unsigned char c = s[i];
        if (c != '\\') {
            if (buf_addc(out, c) < 0) return -1;
            i++;
            continue;
        }
        if (i + 1 >= end) return -1;
        unsigned char e = s[i + 1];
        if (e != 'u') {
            unsigned char r;
            switch (e) {
            case '"': r = '"'; break;
            case '\\': r = '\\'; break;
            case '/': r = '/'; break;
            case 'b': r = '\b'; break;
            case 'f': r = '\f'; break;
            case 'n': r = '\n'; break;
            case 'r': r = '\r'; break;
            case 't': r = '\t'; break;
            default: return -1;
            }
            if (buf_addc(out, r) < 0) return -1;
            i += 2;
            continue;
        }
        if (end - i < 6) return -1;
        unsigned long cp = 0;
        for (size_t k = 2; k < 6; k++) {
            if (!is_hex(s[i + k])) return -1;
            cp = cp * 16 + hex_val(s[i + k]);
        }
        i += 6;
        if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (end - i < 6 || s[i] != '\\' || s[i + 1] != 'u') return -1;
            unsigned long lo = 0;
            for (size_t k = 2; k < 6; k++) {
                if (!is_hex(s[i + k])) return -1;
                lo = lo * 16 + hex_val(s[i + k]);
            }
            if (lo < 0xDC00 || lo > 0xDFFF) return -1;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            i += 6;
        } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            return -1;
        }
        if (put_utf8(out, cp) < 0) return -1;
    }
    return 0;
}

enum { FIND_NONE = 0, FIND_FOUND = 1, FIND_ERROR = -1 };

/* In the object s[a..b) (already scanned), the value of the top-level key `key`: its range. The last one wins. */
static int obj_find(const unsigned char *s, size_t a, size_t b, const char *key, size_t *va, size_t *vb) {
    if (b <= a || s[a] != '{') return FIND_ERROR;
    size_t klen = strlen(key);
    int found = FIND_NONE;
    size_t i = skip_ws(s, b, a + 1);
    if (i < b && s[i] == '}') return FIND_NONE;
    while (i < b) {
        size_t ke, ve;
        if (s[i] != '"' || scan_string(s, b, i, &ke) < 0) return FIND_ERROR;
        int match = 0;
        if (ke - i - 2 <= 64) {
            unsigned char kb[128];
            struct buf k = {kb, 0, sizeof kb, sizeof kb};
            if (json_decode_string(&k, s, i, ke) == 0 && k.len == klen && memcmp(kb, key, klen) == 0) match = 1;
        }
        i = skip_ws(s, b, ke);
        if (i >= b || s[i] != ':') return FIND_ERROR;
        i = skip_ws(s, b, i + 1);
        if (scan_value(s, b, i, 1, &ve) < 0) return FIND_ERROR;
        if (match) { *va = i; *vb = ve; found = FIND_FOUND; }
        i = skip_ws(s, b, ve);
        if (i < b && s[i] == '}') return found;
        if (i >= b || s[i] != ',') return FIND_ERROR;
        i = skip_ws(s, b, i + 1);
    }
    return FIND_ERROR;
}

/* The decoded string value of `key` in the object s[a..b), at most `max` bytes. FIND_NONE when the key is absent or its
 * value is not a string. */
static int obj_string(const unsigned char *s, size_t a, size_t b, const char *key, struct buf *out) {
    size_t va, vb;
    int r = obj_find(s, a, b, key, &va, &vb);
    if (r != FIND_FOUND) return r;
    if (s[va] != '"') return FIND_NONE;
    return json_decode_string(out, s, va, vb) == 0 ? FIND_FOUND : FIND_ERROR;
}

/* The elements of the top-level object's `messages` array: up to `max` ranges into starts/ends; *count how many. */
typedef int (*element_fn)(void *ctx, const unsigned char *s, size_t a, size_t b);

static int each_message(const unsigned char *s, size_t n, element_fn fn, void *ctx, size_t *count) {
    size_t a, b, va, vb;
    *count = 0;
    if (scan_document(s, n, &a, &b) < 0 || s[a] != '{') return -1;
    if (obj_find(s, a, b, "messages", &va, &vb) != FIND_FOUND || s[va] != '[') return -1;
    size_t i = skip_ws(s, vb, va + 1);
    if (i < vb && s[i] == ']') return 0;
    while (i < vb) {
        size_t e;
        if (scan_value(s, vb, i, 1, &e) < 0) return -1;
        (*count)++;
        if (fn && fn(ctx, s, i, e) != 0) return 1;
        i = skip_ws(s, vb, e);
        if (i < vb && s[i] == ']') return 0;
        if (i >= vb || s[i] != ',') return -1;
        i = skip_ws(s, vb, i + 1);
    }
    return -1;
}

/* An id an acknowledgement gives back: printable ASCII, at most 256 bytes (absent: ""). */
static int ack_id(const unsigned char *s, size_t a, size_t b, const char *key, char *out) {
    struct buf v = buf_new(MAX_ID);
    int r = obj_string(s, a, b, key, &v);
    if (r == FIND_ERROR) { buf_free(&v); return -1; }
    for (size_t i = 0; i < v.len; i++)
        if (v.p[i] < 0x20 || v.p[i] > 0x7E) { buf_free(&v); return -1; }
    if (v.len) memcpy(out, v.p, v.len);
    out[v.len] = 0;
    buf_free(&v);
    return 0;
}

/* ---------------------------------------------------------------------------------------------------------------
 * base64 (RFC 4648, padded) with checked sizes.
 * ------------------------------------------------------------------------------------------------------------ */

static int base64_size(size_t n, size_t *out) {
    if (n > (SIZE_MAX - 2) / 4 * 3) return -1;
    *out = (n + 2) / 3 * 4;
    return 0;
}

static int base64_append(struct buf *out, const unsigned char *s, size_t n) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t need;
    if (base64_size(n, &need) < 0 || buf_reserve(out, need) < 0) return -1;
    size_t i = 0;
    unsigned char *o = out->p + out->len;
    while (n - i >= 3) {
        unsigned v = ((unsigned)s[i] << 16) | ((unsigned)s[i + 1] << 8) | s[i + 2];
        *o++ = (unsigned char)t[(v >> 18) & 63]; *o++ = (unsigned char)t[(v >> 12) & 63];
        *o++ = (unsigned char)t[(v >> 6) & 63]; *o++ = (unsigned char)t[v & 63];
        i += 3;
    }
    if (n - i == 1) {
        unsigned v = (unsigned)s[i] << 16;
        *o++ = (unsigned char)t[(v >> 18) & 63]; *o++ = (unsigned char)t[(v >> 12) & 63]; *o++ = '='; *o++ = '=';
    } else if (n - i == 2) {
        unsigned v = ((unsigned)s[i] << 16) | ((unsigned)s[i + 1] << 8);
        *o++ = (unsigned char)t[(v >> 18) & 63]; *o++ = (unsigned char)t[(v >> 12) & 63];
        *o++ = (unsigned char)t[(v >> 6) & 63]; *o++ = '=';
    }
    out->len += need;
    return 0;
}

/* ---------------------------------------------------------------------------------------------------------------
 * clean_name: the chat server's rule for a stored name (ChatFileRules.cleanName): backslashes are separators,
 * trailing slashes go, the last part; per Unicode scalar, A-Za-z0-9._ ()+- kept and anything else one "_" (an invalid
 * byte is one "_" here); leading dots and spaces dropped; "file" when nothing is left; the last 120 bytes.
 * ------------------------------------------------------------------------------------------------------------ */

#define CLEAN_MAX 120

static void clean_name(const char *raw, char out[CLEAN_MAX + 1]) {
    size_t n = strlen(raw);
    /* Trailing separators go (while more than one byte is left). */
    while (n > 1 && (raw[n - 1] == '/' || raw[n - 1] == '\\')) n--;
    size_t start = 0;
    if (!(n == 1 && (raw[0] == '/' || raw[0] == '\\')))
        for (size_t i = 0; i < n; i++)
            if (raw[i] == '/' || raw[i] == '\\') start = i + 1;
    /* Map, keeping only the LAST 120 output bytes (each output byte is one ASCII character). */
    char ring[CLEAN_MAX];
    size_t total = 0, lead = 1, kept = 0;
    size_t i = start;
    /* First pass: build the mapped string with leading dots and spaces dropped, then keep the tail. */
    while (i < n) {
        const unsigned char *u = (const unsigned char *)raw + i;
        size_t k = utf8_seq(u, n - i);
        char c;
        if (k == 0) { k = 1; c = '_'; }
        else if (k == 1) {
            unsigned char b = u[0];
            int ok = (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '.' || b == '_' ||
                     b == ' ' || b == '(' || b == ')' || b == '+' || b == '-';
            c = ok ? (char)b : '_';
        } else c = '_';
        i += k;
        if (lead && (c == '.' || c == ' ')) continue;
        lead = 0;
        ring[total % CLEAN_MAX] = c;
        total++;
    }
    if (total == 0) {
        memcpy(out, "file", 5);
        return;
    }
    kept = total < CLEAN_MAX ? total : CLEAN_MAX;
    for (size_t j = 0; j < kept; j++) out[j] = ring[(total - kept + j) % CLEAN_MAX];
    out[kept] = 0;
}

/* ---------------------------------------------------------------------------------------------------------------
 * Words for a person (stderr, "dozchat: "), scrubbed of the token and the proxy's password.
 * ------------------------------------------------------------------------------------------------------------ */

static void scrub(char *t, size_t n) {
    const struct { const char *p; size_t n; } secrets[] = {
        {g_token, g_token_len}, {g_proxy_secret, g_proxy_secret_len}, {g_proxy_auth, g_proxy_auth_len}};
    for (size_t s = 0; s < 3; s++) {
        if (secrets[s].n < 4) continue;
        for (;;) {
            size_t at = find_bytes((const unsigned char *)t, n, (const unsigned char *)secrets[s].p, secrets[s].n);
            if (at == SIZE_MAX) break;
            memset(t + at, '*', secrets[s].n);
        }
    }
}

__attribute__((format(printf, 1, 2))) static void say(const char *fmt, ...) {
    char t[1024];
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(t, sizeof t, fmt, ap);
    va_end(ap);
    if (r < 0) return;
    size_t n = strlen(t);
    for (size_t i = 0; i < n; i++)
        if ((unsigned char)t[i] < 0x20 && t[i] != '\t') t[i] = ' ';
    scrub(t, n);
    fputs("dozchat: ", stderr);
    fputs(t, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

/* A server's reason, made safe to show: control bytes dropped, at most MAX_REASON bytes (never cut inside a character). */
static void reason_text(const unsigned char *s, size_t n, char out[MAX_REASON + 1]) {
    size_t o = 0, i = 0;
    while (i < n && o < MAX_REASON) {
        size_t k = utf8_seq(s + i, n - i);
        if (k == 0) { out[o++] = '?'; i++; continue; }
        if (k == 1) {
            unsigned char c = s[i];
            out[o++] = (c < 0x20 || c == 0x7F) ? ' ' : (char)c;
            i++;
            continue;
        }
        if (o + k > MAX_REASON) break;
        memcpy(out + o, s + i, k);
        o += k;
        i += k;
    }
    while (o > 0 && out[o - 1] == ' ') o--;
    size_t lead = 0;
    while (lead < o && out[lead] == ' ') lead++;
    if (lead) memmove(out, out + lead, o - lead);
    out[o - lead] = 0;
    scrub(out, o - lead);
}

/* One line on stdout, flushed; -1 when stdout is gone. */
static int out_line(const unsigned char *p, size_t n) {
    if (n && fwrite(p, 1, n, stdout) != n) return -1;
    if (fputc('\n', stdout) == EOF) return -1;
    return fflush(stdout) == 0 ? 0 : -1;
}

/* ---------------------------------------------------------------------------------------------------------------
 * Addresses: CHAT_URL, the proxy's URL, NO_PROXY.
 * ------------------------------------------------------------------------------------------------------------ */

struct url {
    char host[256];      /* for the resolver: an IPv6 literal without its brackets */
    char authority[300]; /* for Host: and the absolute form: host, [v6], and :port when not 80 */
    unsigned port;
    size_t path_at;      /* where the path starts in the text (its length when there is none) */
};

enum { URL_OK = 0, URL_BAD = -1, URL_HTTPS = -2, URL_USERINFO = -3 };

static int ascii_ieq(const char *a, size_t an, const char *b, size_t bn) {
    if (an != bn) return 0;
    for (size_t i = 0; i < an; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return 0;
    }
    return 1;
}

static int pct_decode(const char *s, size_t n, char *out, size_t cap, size_t *outn) {
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '%') {
            if (n - i < 3 || !is_hex((unsigned char)s[i + 1]) || !is_hex((unsigned char)s[i + 2])) return -1;
            c = (unsigned char)(hex_val((unsigned char)s[i + 1]) * 16 + hex_val((unsigned char)s[i + 2]));
            i += 2;
        }
        if (c < 0x20 || c == 0x7F) return -1;
        if (o + 1 >= cap) return -1;
        out[o++] = (char)c;
    }
    out[o] = 0;
    *outn = o;
    return 0;
}

/* Parse "http://[userinfo@]host[:port][path]". `userinfo`: where it goes (NULL refuses one). */
static int url_parse(const char *u, struct url *out, char *userinfo, size_t uicap, size_t *uilen) {
    size_t n = strlen(u);
    memset(out, 0, sizeof *out);
    if (uilen) *uilen = 0;
    if (n >= 8 && ascii_ieq(u, 8, "https://", 8)) return URL_HTTPS;
    if (n < 7 || !ascii_ieq(u, 7, "http://", 7)) return URL_BAD;
    size_t a = 7, e = a;
    while (e < n && u[e] != '/' && u[e] != '?' && u[e] != '#') e++;
    out->path_at = e;
    size_t at = SIZE_MAX;
    for (size_t i = a; i < e; i++)
        if (u[i] == '@') at = i;
    if (at != SIZE_MAX) {
        if (!userinfo) return URL_USERINFO;
        if (at - a >= uicap) return URL_BAD;
        memcpy(userinfo, u + a, at - a);
        userinfo[at - a] = 0;
        *uilen = at - a;
        a = at + 1;
    }
    size_t hs = a, he;
    size_t pe = e;
    if (a < e && u[a] == '[') {
        size_t c = a + 1;
        while (c < e && u[c] != ']') {
            unsigned char ch = (unsigned char)u[c];
            if (!(is_hex(ch) || ch == ':' || ch == '.')) return URL_BAD;
            c++;
        }
        if (c >= e || c == a + 1) return URL_BAD;
        hs = a + 1;
        he = c;
        a = c + 1;
        if (a < e && u[a] != ':') return URL_BAD;
    } else {
        size_t c = a;
        while (c < e && u[c] != ':') {
            unsigned char ch = (unsigned char)u[c];
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '_'))
                return URL_BAD;
            c++;
        }
        he = c;
        a = c;
    }
    if (he == hs || he - hs > 253) return URL_BAD;
    unsigned port = 80;
    if (a < pe && u[a] == ':') {
        size_t d = a + 1;
        if (d >= pe || pe - d > 5) return URL_BAD;
        port = 0;
        for (size_t i = d; i < pe; i++) {
            if (u[i] < '0' || u[i] > '9') return URL_BAD;
            port = port * 10 + (unsigned)(u[i] - '0');
        }
        if (port == 0 || port > 65535) return URL_BAD;
    } else if (a != pe) return URL_BAD;
    memcpy(out->host, u + hs, he - hs);
    out->host[he - hs] = 0;
    out->port = port;
    int v6 = hs > 7 && u[hs - 1] == '[';
    int r = port == 80 ? snprintf(out->authority, sizeof out->authority, v6 ? "[%s]" : "%s", out->host)
                       : snprintf(out->authority, sizeof out->authority, v6 ? "[%s]:%u" : "%s:%u", out->host, port);
    if (r < 0 || (size_t)r >= sizeof out->authority) return URL_BAD;
    return URL_OK;
}

/* CHAT_URL: a path of slashes only (a trailing one is tidied away), no query. */
static int chat_url_parse(const char *u, struct url *out) {
    int r = url_parse(u, out, NULL, 0, NULL);
    if (r != URL_OK) return r;
    for (size_t i = out->path_at; u[i]; i++)
        if (u[i] != '/') return URL_BAD;
    return URL_OK;
}

/* NO_PROXY: comma-separated exact host names (any case, brackets ignored), or "*". */
static int no_proxy_matches(const char *list, const char *host) {
    if (!list) return 0;
    size_t hn = strlen(host);
    const char *p = list;
    while (*p) {
        const char *q = p;
        while (*q && *q != ',') q++;
        const char *a = p, *b = q;
        while (a < b && (*a == ' ' || *a == '\t')) a++;
        while (b > a && (b[-1] == ' ' || b[-1] == '\t')) b--;
        if (b - a >= 2 && *a == '[' && b[-1] == ']') { a++; b--; }
        if (b - a == 1 && *a == '*') return 1;
        if (ascii_ieq(a, (size_t)(b - a), host, hn)) return 1;
        p = *q ? q + 1 : q;
    }
    return 0;
}

/* ---------------------------------------------------------------------------------------------------------------
 * The answer's head: "HTTP/1.x DDD", header lines of at most 8 KiB, at most 64 KiB in all; exactly one Content-Length
 * (digits only, no larger than the cap) or none; any Transfer-Encoding refused; no folded lines.
 * ------------------------------------------------------------------------------------------------------------ */

struct head {
    int status;
    long long length; /* -1: none (read to the close) */
    size_t size;      /* the head's bytes, its blank line included */
    char type[MAX_TYPE + 1];
};

enum { HEAD_OK = 0, HEAD_MORE = 1, HEAD_BAD = -1, HEAD_CHUNKED = -2, HEAD_TOO_BIG = -3 };

static int head_parse(const unsigned char *s, size_t n, size_t cap, struct head *h) {
    memset(h, 0, sizeof *h);
    h->length = -1;
    size_t end = find_bytes(s, n < MAX_HEAD ? n : MAX_HEAD, (const unsigned char *)"\r\n\r\n", 4);
    if (end == SIZE_MAX) return n >= MAX_HEAD ? HEAD_TOO_BIG : HEAD_MORE;
    h->size = end + 4;
    /* The status line. */
    size_t le = find_bytes(s, end + 2, (const unsigned char *)"\r\n", 2);
    if (le == SIZE_MAX || le > MAX_HEADER_LINE) return HEAD_BAD;
    if (le < 12 || memcmp(s, "HTTP/1.", 7) != 0 || s[7] < '0' || s[7] > '9' || s[8] != ' ') return HEAD_BAD;
    for (size_t i = 9; i < 12; i++)
        if (s[i] < '0' || s[i] > '9') return HEAD_BAD;
    if (le > 12 && s[12] != ' ') return HEAD_BAD;
    h->status = (s[9] - '0') * 100 + (s[10] - '0') * 10 + (s[11] - '0');
    int lengths = 0;
    size_t i = le + 2;
    while (i < end + 2) {
        size_t e2 = find_bytes(s + i, end + 2 - i, (const unsigned char *)"\r\n", 2);
        if (e2 == SIZE_MAX) return HEAD_BAD;
        size_t a = i, b = i + e2;
        if (b - a > MAX_HEADER_LINE) return HEAD_BAD;
        if (s[a] == ' ' || s[a] == '\t') return HEAD_BAD; /* a folded line */
        size_t colon = a;
        while (colon < b && s[colon] != ':') {
            unsigned char c = s[colon];
            if (c <= 0x20 || c >= 0x7F) return HEAD_BAD;
            colon++;
        }
        if (colon == a || colon == b) return HEAD_BAD;
        size_t va = colon + 1, vb = b;
        while (va < vb && (s[va] == ' ' || s[va] == '\t')) va++;
        while (vb > va && (s[vb - 1] == ' ' || s[vb - 1] == '\t')) vb--;
        for (size_t k = va; k < vb; k++)
            if ((s[k] < 0x20 && s[k] != '\t') || s[k] == 0x7F) return HEAD_BAD;
        const char *name = (const char *)s + a;
        size_t nl = colon - a;
        if (ascii_ieq(name, nl, "transfer-encoding", 17)) return HEAD_CHUNKED;
        if (ascii_ieq(name, nl, "content-length", 14)) {
            if (++lengths > 1 || va == vb || vb - va > 18) return HEAD_BAD;
            long long v = 0;
            for (size_t k = va; k < vb; k++) {
                if (s[k] < '0' || s[k] > '9') return HEAD_BAD;
                v = v * 10 + (s[k] - '0');
            }
            if ((unsigned long long)v > cap) return HEAD_TOO_BIG;
            h->length = v;
        }
        if (ascii_ieq(name, nl, "content-type", 12)) {
            size_t o = 0;
            for (size_t k = va; k < vb && o < MAX_TYPE; k++)
                if (s[k] >= 0x20 && s[k] < 0x7F) h->type[o++] = (char)s[k];
            h->type[o] = 0;
        }
        i = b + 2;
    }
    return HEAD_OK;
}

/* ---------------------------------------------------------------------------------------------------------------
 * One HTTP call: one TCP connection (to the proxy, or straight to the chat server), non-blocking with a deadline.
 * ------------------------------------------------------------------------------------------------------------ */

static struct url g_chat;
static char g_chat_base[320]; /* "http://AUTHORITY", for words */
static struct url g_proxy;
static int g_use_proxy;
static char g_why[512];

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static int left_ms(double deadline) {
    double l = deadline - now_s();
    if (l <= 0) return 0;
    if (l > 3600) l = 3600;
    return (int)(l * 1000) + 1;
}

static void set_why_errno(const char *what, int e) {
    int r = snprintf(g_why, sizeof g_why, "the chat server at %s did not answer: %s (%s)", g_chat_base, what, strerror(e));
    (void)r;
}

static void set_why(const char *what) {
    int r = snprintf(g_why, sizeof g_why, "the chat server at %s did not answer: %s", g_chat_base, what);
    (void)r;
}

static int dial(double deadline) {
    const struct url *to = g_use_proxy ? &g_proxy : &g_chat;
    char port[8];
    int pr = snprintf(port, sizeof port, "%u", to->port);
    if (pr < 0 || (size_t)pr >= sizeof port) return -1;
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int g = getaddrinfo(to->host, port, &hints, &res);
    if (g != 0 || !res) {
        set_why(g_use_proxy ? "the proxy's name does not resolve" : "its name does not resolve");
        return -1;
    }
    int fd = -1, last = ECONNREFUSED;
    double cd = now_s() + CONNECT_TIMEOUT;
    if (cd > deadline) cd = deadline;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { last = errno; continue; }
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
#if defined(SO_NOSIGPIPE)
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        if (errno == EINPROGRESS || errno == EINTR) {
            struct pollfd p = {fd, POLLOUT, 0};
            int pr2;
            do { pr2 = poll(&p, 1, left_ms(cd)); } while (pr2 < 0 && errno == EINTR);
            if (pr2 == 1) {
                int err = 0;
                socklen_t el = sizeof err;
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0) break;
                last = err ? err : ECONNREFUSED;
            } else last = ETIMEDOUT;
        } else last = errno;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) set_why_errno(g_use_proxy ? "could not connect to the session's proxy" : "could not connect", last);
    return fd;
}

static int send_all(int fd, const unsigned char *p, size_t n, double deadline) {
    size_t off = 0;
    while (off < n) {
#if defined(MSG_NOSIGNAL)
        ssize_t w = send(fd, p + off, n - off, MSG_NOSIGNAL);
#else
        ssize_t w = send(fd, p + off, n - off, 0);
#endif
        if (w > 0) { off += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd q = {fd, POLLOUT, 0};
            int r = poll(&q, 1, left_ms(deadline));
            if (r == 0) { set_why("timed out sending"); return -1; }
            continue;
        }
        set_why_errno("the connection broke while sending", errno);
        return -1;
    }
    return 0;
}

struct answer {
    int status;
    struct buf body;
    char type[MAX_TYPE + 1];
};

/* One call. Returns EXIT_DONE with `ans` filled (any status), or EXIT_AWAY (no answer, a timeout, a cut answer) or
 * EXIT_LOCAL (a broken or oversized answer; a local failure) with g_why set. */
static int http_call(const char *method, const char *path, const unsigned char *body, size_t body_len, int timeout_s,
                     size_t cap, struct answer *ans) {
    double deadline = now_s() + timeout_s;
    memset(ans, 0, sizeof *ans);
    ans->body = buf_new(cap);
    struct buf req = buf_new(MAX_REQUEST_BODY + 64 * KIB);
    int bad = 0;
    bad |= buf_adds(&req, method) | buf_addc(&req, ' ');
    if (g_use_proxy) bad |= buf_adds(&req, "http://") | buf_adds(&req, g_chat.authority);
    bad |= buf_adds(&req, path) | buf_adds(&req, " HTTP/1.1\r\nHost: ") | buf_adds(&req, g_chat.authority);
    bad |= buf_adds(&req, "\r\nUser-Agent: dozchat/" DOZCHAT_VERSION "\r\nAccept: application/json\r\nAuthorization: Bearer ");
    bad |= buf_add(&req, g_token, g_token_len);
    if (g_use_proxy && g_proxy_auth_len)
        bad |= buf_adds(&req, "\r\nProxy-Authorization: Basic ") | buf_add(&req, g_proxy_auth, g_proxy_auth_len);
    if (body) bad |= buf_adds(&req, "\r\nContent-Type: application/json\r\nContent-Length: ") | buf_addu(&req, body_len);
    bad |= buf_adds(&req, "\r\nConnection: close\r\n\r\n");
    if (body) bad |= buf_add(&req, body, body_len);
    if (bad) {
        buf_free(&req);
        snprintf(g_why, sizeof g_why, "the request is larger than %zu MiB", (size_t)(MAX_REQUEST_BODY / MIB));
        return EXIT_LOCAL;
    }
    int fd = dial(deadline);
    if (fd < 0) { buf_free(&req); return EXIT_AWAY; }
    int sent = send_all(fd, req.p, req.len, deadline);
    buf_free(&req); /* it held the token */
    /* A write that failed (a proxy that refused us may answer and close before reading the body): whatever answer
     * already arrived is still read — briefly — before deciding. No answer: the write's failure stands (EXIT_AWAY). */
    int cut = sent < 0;
    char send_why[sizeof g_why];
    memcpy(send_why, g_why, sizeof g_why);
    double rdeadline = deadline;
    if (cut && now_s() + 2 < rdeadline) rdeadline = now_s() + 2;
    struct buf in = buf_new(cap > SIZE_MAX - MAX_HEAD ? SIZE_MAX : cap + MAX_HEAD);
    struct head h;
    memset(&h, 0, sizeof h);
    int have_head = 0, rc = EXIT_DONE;
    unsigned char chunk[16384];
    for (;;) {
        if (have_head && h.length >= 0 && in.len - h.size >= (size_t)h.length) break;
        struct pollfd p = {fd, POLLIN, 0};
        int pr = poll(&p, 1, left_ms(rdeadline));
        if (pr < 0 && errno == EINTR) continue;
        if (pr == 0) {
            if (cut && have_head) break; /* the refusal's head is what counts */
            if (cut) memcpy(g_why, send_why, sizeof g_why);
            else set_why("timed out waiting for the answer");
            rc = EXIT_AWAY;
            break;
        }
        ssize_t r = recv(fd, chunk, sizeof chunk, 0);
        if (r < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (r < 0) {
            if (have_head && (cut || h.status >= 400)) break; /* a reset after an answer's head: the answer stands */
            if (cut) memcpy(g_why, send_why, sizeof g_why);
            else set_why_errno("the connection broke", errno);
            rc = EXIT_AWAY;
            break;
        }
        if (r == 0) {
            if (!have_head) {
                if (cut) memcpy(g_why, send_why, sizeof g_why);
                else set_why(in.len ? "the answer was cut off" : "the connection closed without an answer");
                rc = EXIT_AWAY;
            } else if (h.length >= 0 && !cut && h.status < 400) { set_why("the answer was cut off"); rc = EXIT_AWAY; }
            break;
        }
        if (buf_add(&in, chunk, (size_t)r) < 0) {
            snprintf(g_why, sizeof g_why, "the answer is larger than %zu MiB; not read", cap / MIB);
            rc = EXIT_LOCAL;
            break;
        }
        if (!have_head) {
            int hp = head_parse(in.p, in.len, cap, &h);
            if (hp == HEAD_MORE) continue;
            if (hp == HEAD_CHUNKED) { snprintf(g_why, sizeof g_why, "a broken answer from %s: chunked encoding is not accepted", g_chat_base); rc = EXIT_LOCAL; break; }
            if (hp == HEAD_TOO_BIG) { snprintf(g_why, sizeof g_why, "the answer is larger than %zu MiB; not read", cap / MIB); rc = EXIT_LOCAL; break; }
            if (hp != HEAD_OK) { snprintf(g_why, sizeof g_why, "a broken answer from %s: a head that is not well-formed HTTP/1.x", g_chat_base); rc = EXIT_LOCAL; break; }
            have_head = 1;
        }
    }
    close(fd);
    if (rc == EXIT_DONE) {
        size_t blen = in.len - h.size;
        if (h.length >= 0 && blen > (size_t)h.length) blen = (size_t)h.length;
        if (buf_add(&ans->body, in.p + h.size, blen) < 0) {
            snprintf(g_why, sizeof g_why, "the answer is larger than %zu MiB; not read", cap / MIB);
            rc = EXIT_LOCAL;
        }
        ans->status = h.status;
        memcpy(ans->type, h.type, sizeof ans->type);
    }
    buf_free(&in);
    if (rc != EXIT_DONE) buf_free(&ans->body);
    return rc;
}

/* What a failed answer means: its exit code and the words for it (the server's own reason). */
static int answer_failure(const struct answer *a) {
    char why[MAX_REASON + 1] = "";
    size_t s0, s1;
    const unsigned char *b = a->body.p;
    size_t n = a->body.len;
    if (n && scan_document(b, n, &s0, &s1) == 0 && b[s0] == '{') {
        struct buf v = buf_new(4096);
        if (obj_string(b, s0, s1, "error", &v) == FIND_FOUND && v.len) reason_text(v.p, v.len, why);
        else {
            v.len = 0;
            if (obj_string(b, s0, s1, "detail", &v) == FIND_FOUND && v.len) reason_text(v.p, v.len, why);
        }
        buf_free(&v);
    }
    if (!why[0] && n) reason_text(b, n < 200 ? n : 200, why);
    if (!why[0]) memcpy(why, "no text", 8);
    int st = a->status;
    /* The session's proxy said no before relaying anything: 407 always is the proxy's; a 401 through a proxy that is not
     * the chat server's JSON is too. Exit 4, never retried; never the proxy's address or password. */
    int json = n && scan_document(b, n, &s0, &s1) == 0 && b[s0] == '{';
    if (st == 407 || (g_use_proxy && st == 401 && !json)) {
        say("the proxy refused the credentials (HTTP %d)", st);
        return EXIT_DENIED;
    }
    if (st == 422) { say("refused: %s", why); return EXIT_REFUSED; }
    if (st == 401 || st == 403 || st == 409) { say("HTTP %d: %s", st, why); return EXIT_DENIED; }
    if (st >= 500) { say("HTTP %d from the chat server: %s", st, why); return EXIT_AWAY; }
    if (st >= 300 && st < 400) { say("unexpected answer HTTP %d: %s (redirects are never followed)", st, why); return EXIT_LOCAL; }
    say("unexpected answer HTTP %d: %s", st, why);
    return EXIT_LOCAL;
}

/* A JSON call: on 200 the answer is a JSON document (its range in *a0..*a1); otherwise the failure's code (said). A 422
 * answer is printed on stdout first. `quiet_away`: an EXIT_AWAY is not said here (the caller retries and says so). */
static int json_call(const char *method, const char *path, const struct buf *body, int timeout_s, struct answer *ans,
                     size_t *a0, size_t *a1, int quiet_away) {
    int rc = http_call(method, path, body ? body->p : NULL, body ? body->len : 0, timeout_s, MAX_ANSWER, ans);
    if (rc != EXIT_DONE) {
        if (!(quiet_away && rc == EXIT_AWAY)) say("%s", g_why);
        return rc;
    }
    if (ans->status == 200) {
        if (scan_document(ans->body.p, ans->body.len, a0, a1) == 0) return EXIT_DONE;
        snprintf(g_why, sizeof g_why, "a broken answer from the chat server (HTTP 200, not JSON)");
        if (!quiet_away) say("%s", g_why);
        buf_free(&ans->body);
        return EXIT_AWAY;
    }
    if (ans->status == 422) {
        size_t s0, s1;
        if (scan_document(ans->body.p, ans->body.len, &s0, &s1) == 0) {
            struct buf c = buf_new(MAX_ANSWER);
            if (json_compact(&c, ans->body.p, s0, s1) == 0) (void)out_line(c.p, c.len);
            buf_free(&c);
        }
    }
    if (quiet_away && ans->status >= 500) {
        int rc2 = EXIT_AWAY;
        snprintf(g_why, sizeof g_why, "HTTP %d from the chat server", ans->status);
        buf_free(&ans->body);
        return rc2;
    }
    rc = answer_failure(ans);
    buf_free(&ans->body);
    return rc;
}

/* ---------------------------------------------------------------------------------------------------------------
 * Configuration.
 * ------------------------------------------------------------------------------------------------------------ */

static int token_usable(const char *t, size_t n) {
    if (n < 16) return 0;
    for (size_t i = 0; i < n; i++)
        if ((unsigned char)t[i] <= 0x20 || (unsigned char)t[i] >= 0x7F) return 0;
    return 1;
}

/* Trim ASCII whitespace off both ends of g_token in place. */
static void token_trim(void) {
    size_t a = 0, b = g_token_len;
    while (a < b && (g_token[a] == ' ' || g_token[a] == '\t' || g_token[a] == '\n' || g_token[a] == '\r')) a++;
    while (b > a && (g_token[b - 1] == ' ' || g_token[b - 1] == '\t' || g_token[b - 1] == '\n' || g_token[b - 1] == '\r')) b--;
    if (a) memmove(g_token, g_token + a, b - a);
    wipe(g_token + (b - a), sizeof g_token - (b - a));
    g_token_len = b - a;
}

static int read_token(void) {
    const char *file = getenv("CHAT_TOKEN_FILE");
    if (file && *file) {
        int fd = open(file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (fd < 0) {
            if (errno == ELOOP) say("CHAT_TOKEN_FILE must be a regular file, not a link");
            else say("CHAT_TOKEN_FILE cannot be read: %s", strerror(errno));
            return EXIT_USAGE;
        }
        struct stat st;
        if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
            close(fd);
            say("CHAT_TOKEN_FILE must be a regular file, not a link");
            return EXIT_USAGE;
        }
        if (st.st_uid != getuid() || (st.st_mode & 077)) {
            close(fd);
            say("CHAT_TOKEN_FILE must be yours alone: chmod 600 it");
            return EXIT_USAGE;
        }
        if (st.st_size > MAX_TOKEN_FILE) {
            close(fd);
            say("CHAT_TOKEN_FILE is larger than 4 KiB: not a token");
            return EXIT_USAGE;
        }
        size_t got = 0;
        while (got < MAX_TOKEN_FILE) {
            ssize_t r = read(fd, g_token + got, MAX_TOKEN_FILE - got);
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) break;
            got += (size_t)r;
        }
        close(fd);
        g_token_len = got;
    } else {
        const char *t = getenv("CHAT_TOKEN");
        size_t n = t ? strlen(t) : 0;
        if (n > MAX_TOKEN_FILE) {
            say("CHAT_TOKEN is longer than 4 KiB: not a token");
            return EXIT_USAGE;
        }
        if (n) memcpy(g_token, t, n);
        g_token_len = n;
    }
    token_trim();
    if (!g_token_len) {
        say("no token: set CHAT_TOKEN_FILE (a file only you can read) or CHAT_TOKEN");
        return EXIT_USAGE;
    }
    if (!token_usable(g_token, g_token_len)) {
        wipe_secrets();
        say("the token is not usable: at least 16 printable characters, no spaces");
        return EXIT_USAGE;
    }
    return EXIT_DONE;
}

static int read_proxy(void) {
    const char *p = getenv("http_proxy");
    if (!p || !*p) p = getenv("HTTP_PROXY");
    g_use_proxy = 0;
    if (!p || !*p) return EXIT_DONE;
    const char *np = getenv("no_proxy");
    if (!np || !*np) np = getenv("NO_PROXY");
    if (no_proxy_matches(np, g_chat.host)) return EXIT_DONE;
    char ui[1100];
    size_t uil = 0;
    int r = url_parse(p, &g_proxy, ui, sizeof ui, &uil);
    if (r != URL_OK) {
        wipe(ui, sizeof ui);
        say("http_proxy is not usable: an http:// proxy address is needed (it is not shown: it may hold a password)");
        return EXIT_USAGE;
    }
    for (size_t i = g_proxy.path_at; p[i]; i++)
        if (p[i] != '/') {
            wipe(ui, sizeof ui);
            say("http_proxy is not usable: an http:// proxy address with no path is needed (it is not shown)");
            return EXIT_USAGE;
        }
    if (uil) {
        char user[1100];
        size_t un = 0, pn = 0;
        size_t colon = SIZE_MAX;
        for (size_t i = 0; i < uil; i++)
            if (ui[i] == ':') { colon = i; break; }
        size_t ulen = colon == SIZE_MAX ? uil : colon;
        int bad = pct_decode(ui, ulen, user, sizeof user, &un) < 0;
        if (!bad && colon != SIZE_MAX)
            bad = pct_decode(ui + colon + 1, uil - colon - 1, g_proxy_secret, sizeof g_proxy_secret, &pn) < 0;
        wipe(ui, sizeof ui);
        if (bad) {
            wipe(user, sizeof user);
            wipe_secrets();
            say("http_proxy is not usable: its user or password is not well formed (it is not shown)");
            return EXIT_USAGE;
        }
        g_proxy_secret_len = pn;
        struct buf cred = buf_new(sizeof user + sizeof g_proxy_secret);
        struct buf b64 = buf_new(sizeof g_proxy_auth - 1);
        int e = buf_add(&cred, user, un) | buf_addc(&cred, ':') | buf_add(&cred, g_proxy_secret, pn);
        wipe(user, sizeof user);
        if (e || base64_append(&b64, cred.p, cred.len) < 0) {
            buf_free(&cred);
            buf_free(&b64);
            wipe_secrets();
            say("http_proxy is not usable: its user and password are too long");
            return EXIT_USAGE;
        }
        memcpy(g_proxy_auth, b64.p, b64.len);
        g_proxy_auth_len = b64.len;
        buf_free(&cred);
        buf_free(&b64);
    }
    g_use_proxy = 1;
    return EXIT_DONE;
}

/* The address when CHAT_URL is not set. */
static const char *default_url(void) {
#if defined(__APPLE__)
    const char *p = getenv("http_proxy");
    if (!p || !*p) p = getenv("HTTP_PROXY");
    if (!p || !*p) return MAC_DIRECT_URL;
#endif
    return DEFAULT_URL;
}

static int configure(void) {
    const char *u = getenv("CHAT_URL");
    if (!u || !*u) u = default_url();
    int r = chat_url_parse(u, &g_chat);
    if (r == URL_HTTPS) { say("CHAT_URL: plain http only; outside Dozable use chat_client.py"); return EXIT_USAGE; }
    if (r == URL_USERINFO) { say("CHAT_URL must not hold a user or password (it is not shown)"); return EXIT_USAGE; }
    if (r != URL_OK) { say("CHAT_URL must be http://HOST[:PORT], with no path or query"); return EXIT_USAGE; }
    int b = snprintf(g_chat_base, sizeof g_chat_base, "http://%s", g_chat.authority);
    if (b < 0 || (size_t)b >= sizeof g_chat_base) return EXIT_USAGE;
    if ((r = read_proxy()) != EXIT_DONE) return r;
    return read_token();
}

/* ---------------------------------------------------------------------------------------------------------------
 * The calls.
 * ------------------------------------------------------------------------------------------------------------ */

static int new_uuid(char out[37]) {
    unsigned char r[16];
    if (getentropy(r, sizeof r) != 0) return -1;
    r[6] = (unsigned char)((r[6] & 0x0F) | 0x40);
    r[8] = (unsigned char)((r[8] & 0x3F) | 0x80);
    static const char hex[] = "0123456789abcdef";
    size_t o = 0;
    for (size_t i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[o++] = '-';
        out[o++] = hex[r[i] >> 4];
        out[o++] = hex[r[i] & 15];
    }
    out[o] = 0;
    return 0;
}

static void sleep_s(unsigned s) {
    struct timespec t = {(time_t)s, 0};
    while (nanosleep(&t, &t) < 0 && errno == EINTR) {}
}

struct send_args {
    const char *room;
    const unsigned char *text;
    size_t text_len;
    const char *re;
    const char **to;
    size_t nto;
    int private_;
    const char *att_name;          /* with an attachment */
    const unsigned char *att_data; /* its bytes */
    size_t att_len;
};

/* POST /agent/send, tried 3 times on "no answer" with the SAME msg_id (a repeat is answered "duplicate"). The answer
 * (compact) on stdout unless `detail_out`: then `detail` decoded into it. */
static int do_send(const struct send_args *a, struct buf *detail_out) {
    char id[37];
    if (new_uuid(id) < 0) { say("no random bytes for a msg_id"); return EXIT_LOCAL; }
    struct buf body = buf_new(MAX_REQUEST_BODY);
    int e = buf_adds(&body, "{\"msg_id\":") | json_strz(&body, id) | buf_adds(&body, ",\"message\":{\"content\":");
    int t = json_str(&body, a->text, a->text_len);
    if (t == ESC_INVALID) { buf_free(&body); say("the text is not UTF-8"); return EXIT_USAGE; }
    e |= t | buf_addc(&body, '}');
    if (a->room && *a->room) {
        e |= buf_adds(&body, ",\"room\":");
        int rr = json_strz(&body, a->room);
        if (rr == ESC_INVALID) { buf_free(&body); say("the room is not UTF-8"); return EXIT_USAGE; }
        e |= rr;
    }
    if (a->re && *a->re) {
        e |= buf_adds(&body, ",\"re_msg_id\":");
        int rr = json_strz(&body, a->re);
        if (rr == ESC_INVALID) { buf_free(&body); say("--re is not UTF-8"); return EXIT_USAGE; }
        e |= rr;
    }
    if (a->nto) {
        e |= buf_adds(&body, ",\"to\":[");
        for (size_t i = 0; i < a->nto; i++) {
            const char *nm = a->to[i];
            while (*nm == '@') nm++;
            char low[MAX_ID + 1];
            size_t l = strlen(nm);
            if (l > MAX_ID) { buf_free(&body); say("--to: a name longer than 256 bytes"); return EXIT_USAGE; }
            for (size_t k = 0; k < l; k++) low[k] = (nm[k] >= 'A' && nm[k] <= 'Z') ? (char)(nm[k] - 'A' + 'a') : nm[k];
            low[l] = 0;
            if (i) e |= buf_addc(&body, ',');
            int rr = json_strz(&body, low);
            if (rr == ESC_INVALID) { buf_free(&body); say("--to is not UTF-8"); return EXIT_USAGE; }
            e |= rr;
        }
        e |= buf_addc(&body, ']');
    }
    if (a->private_) e |= buf_adds(&body, ",\"private\":true");
    if (a->att_name) {
        e |= buf_adds(&body, ",\"attachments\":[{\"name\":") | json_strz(&body, a->att_name) | buf_adds(&body, ",\"data_base64\":\"");
        e |= base64_append(&body, a->att_data, a->att_len) | buf_adds(&body, "\"}]");
    }
    e |= buf_addc(&body, '}');
    if (e) { buf_free(&body); say("the message is larger than 32 MiB"); return EXIT_USAGE; }
    int rc = EXIT_AWAY;
    for (int attempt = 0; attempt < 3; attempt++) {
        struct answer ans;
        size_t a0, a1;
        rc = json_call("POST", "/agent/send", &body, a->att_name ? FILE_TIMEOUT : CALL_TIMEOUT, &ans, &a0, &a1, attempt < 2);
        if (rc == EXIT_DONE) {
            if (detail_out) {
                if (ans.body.p[a0] != '{' || obj_string(ans.body.p, a0, a1, "detail", detail_out) == FIND_ERROR) {
                    say("unexpected answer: no detail");
                    rc = EXIT_LOCAL;
                }
            } else {
                struct buf c = buf_new(MAX_ANSWER);
                if (json_compact(&c, ans.body.p, a0, a1) < 0 || out_line(c.p, c.len) < 0) rc = EXIT_LOCAL;
                buf_free(&c);
            }
            buf_free(&ans.body);
            break;
        }
        if (rc != EXIT_AWAY || attempt == 2) break;
        say("%s; trying again in %d s with the same msg_id (a repeat is answered as a duplicate)", g_why, 1 + attempt);
        sleep_s((unsigned)(1 + attempt));
    }
    buf_free(&body);
    return rc;
}

/* The acknowledgement body for one item (room, msg_id, delivery as it came) appended to `acks`. */
static int add_ack(struct buf *acks, int first, const char *room, const char *msg_id, const char *delivery) {
    int e = first ? 0 : buf_addc(acks, ',');
    e |= buf_adds(acks, "{\"room\":") | json_strz(acks, room) | buf_adds(acks, ",\"msg_id\":") | json_strz(acks, msg_id);
    e |= buf_adds(acks, ",\"delivery\":") | json_strz(acks, delivery) | buf_addc(acks, '}');
    return e ? -1 : 0;
}

static int add_ack_item(struct buf *acks, int first, const unsigned char *s, size_t a, size_t b) {
    char room[MAX_ID + 1], msg[MAX_ID + 1], del[MAX_ID + 1];
    if (b <= a || s[a] != '{') return -1;
    if (ack_id(s, a, b, "room", room) < 0 || ack_id(s, a, b, "msg_id", msg) < 0 || ack_id(s, a, b, "delivery", del) < 0) return -1;
    return add_ack(acks, first, room, msg, del);
}

/* POST /agent/ack with `acks` (the array's inside). The answer's `acked` count (compact answer to stdout if `print`). */
static int post_acks(const struct buf *acks, int print, int quiet_away) {
    struct buf body = buf_new(MAX_REQUEST_BODY);
    if (buf_adds(&body, "{\"acks\":[") | buf_add(&body, acks->p, acks->len) | buf_adds(&body, "]}")) {
        buf_free(&body);
        say("too much to acknowledge at once");
        return EXIT_USAGE;
    }
    struct answer ans;
    size_t a0, a1;
    int rc = json_call("POST", "/agent/ack", &body, CALL_TIMEOUT, &ans, &a0, &a1, quiet_away);
    buf_free(&body);
    if (rc != EXIT_DONE) return rc;
    if (print) {
        struct buf c = buf_new(MAX_ANSWER);
        if (json_compact(&c, ans.body.p, a0, a1) < 0 || out_line(c.p, c.len) < 0) rc = EXIT_LOCAL;
        buf_free(&c);
    }
    buf_free(&ans.body);
    return rc;
}

static int get_receive(int wait, int redeliver, struct answer *ans, size_t *a0, size_t *a1, int quiet_away) {
    char path[64];
    int r = snprintf(path, sizeof path, "/agent/receive?wait=%d&ack=1%s", wait, redeliver ? "&redeliver=1" : "");
    if (r < 0 || (size_t)r >= sizeof path) return EXIT_LOCAL;
    int rc = json_call("GET", path, NULL, wait + 15, ans, a0, a1, quiet_away);
    if (rc != EXIT_DONE) return rc;
    size_t count;
    if (ans->body.p[*a0] != '{' || each_message(ans->body.p, ans->body.len, NULL, NULL, &count) != 0) {
        buf_free(&ans->body);
        say("unexpected answer: no messages list");
        return EXIT_LOCAL;
    }
    return EXIT_DONE;
}

struct print_ctx {
    struct buf *acks;
    size_t n;
    int bad;
};

static int print_item(void *vctx, const unsigned char *s, size_t a, size_t b) {
    struct print_ctx *c = vctx;
    struct buf line = buf_new(MAX_ANSWER);
    int rc = json_compact(&line, s, a, b) < 0 || out_line(line.p, line.len) < 0;
    buf_free(&line);
    if (rc) { c->bad = 1; return 1; }
    if (c->acks) {
        if (add_ack_item(c->acks, c->n == 0, s, a, b) < 0) { c->bad = 2; return 1; }
    }
    c->n++;
    return 0;
}

/* ---------------------------------------------------------------------------------------------------------------
 * The command line: options and positionals may be mixed; "--" ends options; --opt=value works.
 * ------------------------------------------------------------------------------------------------------------ */

#define MAX_POS 16
#define MAX_TO 64

struct opts {
    const char *pos[MAX_POS];
    size_t npos;
    const char *room, *re, *out, *name;
    const char *to[MAX_TO];
    size_t nto;
    int dm, ack, redeliver, once, help;
    long wait; /* -1: not given */
};

static const char USAGE[] =
    "usage: dozchat COMMAND ...   (a member of a Dozable chat room; CHAT_URL, CHAT_TOKEN_FILE or CHAT_TOKEN configure it)\n"
    "  dozchat rooms [--room ROOM]                       the rooms you are in: run it first (it works from any room)\n"
    "  dozchat send ROOM TEXT [--re MSG_ID] [--to NAME ...] [--dm]     TEXT - reads it from stdin; options before or after it\n"
    "  dozchat react ROOM MSG_ID REACTION                same as send ROOM \"/react REACTION\" --re MSG_ID\n"
    "  dozchat receive [--wait SECONDS] [--ack] [--redeliver]\n"
    "  dozchat ack ROOM:MSG_ID[:DELIVERY] ...            or: ack -   (reads receive's lines on stdin)\n"
    "  dozchat listen [--wait SECONDS] [--once]          prints every item as it comes, acknowledging each\n"
    "  dozchat file get URL-OR-ID [--out FOLDER] [--name NAME]\n"
    "  dozchat file send ROOM PATH [TEXT] [--re MSG_ID]\n"
    "  dozchat protocol [--room ROOM]                    the protocol, as Markdown\n"
    "  dozchat --version\n"
    "A send answers \"queued\" (it waits for each recipient); a reaction answers \"added\" (recorded at once, it wakes nobody).\n"
    "CHAT_URL defaults to " DEFAULT_URL "; on a Mac with no proxy set, " MAC_DIRECT_URL ". The token is never given on the command line.\n"
    "Outside Dozable, through a local proxy: CHAT_URL=http://HOST:8790 http_proxy=http://localhost:PORT dozchat send ROOM TEXT\n"
    "Exit codes: 0 done, 1 a local problem or a bad answer, 2 usage, 3 refused (422), 4 401/403/409, 5 no answer or 5xx.\n";

static int usage_error(const char *what) {
    say("%s (dozchat --help)", what);
    return EXIT_USAGE;
}

/* `allowed`: the long options this command takes, as " --room --re ". */
static int parse_opts(int argc, char **argv, int from, const char *allowed, struct opts *o) {
    memset(o, 0, sizeof *o);
    o->wait = -1;
    int only_pos = 0;
    for (int i = from; i < argc; i++) {
        const char *a = argv[i];
        if (!only_pos && strcmp(a, "--") == 0) { only_pos = 1; continue; }
        if (only_pos || a[0] != '-' || a[1] == 0) {
            if (o->npos >= MAX_POS) return usage_error("too many arguments");
            o->pos[o->npos++] = a;
            continue;
        }
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) { o->help = 1; continue; }
        char name[32];
        const char *val = NULL;
        const char *eq = strchr(a, '=');
        size_t nl = eq ? (size_t)(eq - a) : strlen(a);
        if (nl >= sizeof name - 2) return usage_error("unknown option");
        name[0] = ' ';
        memcpy(name + 1, a, nl);
        name[nl + 1] = ' ';
        name[nl + 2] = 0;
        if (eq) val = eq + 1;
        if (ascii_ieq(a, nl, "--token", 7) || ascii_ieq(a, nl, "--url", 5) || ascii_ieq(a, nl, "--as", 4))
            return usage_error(nl == 4 ? "there is no --as: the token decides who you are"
                                       : "the token and the address are never given on the command line: set CHAT_TOKEN_FILE and CHAT_URL");
        if (!strstr(allowed, name)) return usage_error("unknown option for this command");
        int flag = strcmp(name, " --dm ") == 0 || strcmp(name, " --ack ") == 0 || strcmp(name, " --redeliver ") == 0 ||
                   strcmp(name, " --once ") == 0;
        if (flag) {
            if (val) return usage_error("that option takes no value");
            if (strcmp(name, " --dm ") == 0) o->dm = 1;
            else if (strcmp(name, " --ack ") == 0) o->ack = 1;
            else if (strcmp(name, " --redeliver ") == 0) o->redeliver = 1;
            else o->once = 1;
            continue;
        }
        if (!val) {
            if (i + 1 >= argc) return usage_error("an option needs its value");
            val = argv[++i];
        }
        if (strcmp(name, " --room ") == 0) o->room = val;
        else if (strcmp(name, " --re ") == 0) o->re = val;
        else if (strcmp(name, " --out ") == 0) o->out = val;
        else if (strcmp(name, " --name ") == 0) o->name = val;
        else if (strcmp(name, " --to ") == 0) {
            if (o->nto >= MAX_TO) return usage_error("too many --to");
            o->to[o->nto++] = val;
        } else if (strcmp(name, " --wait ") == 0) {
            size_t l = strlen(val);
            if (l == 0 || l > 6) return usage_error("--wait takes whole seconds");
            long v = 0;
            for (size_t k = 0; k < l; k++) {
                if (val[k] < '0' || val[k] > '9') return usage_error("--wait takes whole seconds");
                v = v * 10 + (val[k] - '0');
            }
            o->wait = v;
        }
    }
    return EXIT_DONE;
}

static long clamp_wait(long w, long dflt) {
    if (w < 0) w = dflt;
    return w > 50 ? 50 : w;
}

/* ---------------------------------------------------------------------------------------------------------------
 * Commands.
 * ------------------------------------------------------------------------------------------------------------ */

static int read_stdin_all(struct buf *b) {
    unsigned char chunk[65536];
    for (;;) {
        ssize_t r = read(0, chunk, sizeof chunk);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) return -1;
        if (r == 0) return 0;
        if (buf_add(b, chunk, (size_t)r) < 0) return -2;
    }
}

static int cmd_send(const struct opts *o) {
    if (o->npos < 2) return usage_error("send takes ROOM TEXT");
    if (o->npos > 2 && strcmp(o->pos[1], "-") == 0) return usage_error("send ROOM - reads the text from stdin and takes no other words");
    if (o->dm && o->nto == 0) return usage_error("--dm needs --to NAME");
    int rc = configure();
    if (rc) return rc;
    struct buf in = buf_new(MAX_STDIN_TEXT);
    struct send_args a;
    memset(&a, 0, sizeof a);
    a.room = o->pos[0];
    a.re = o->re;
    a.to = (const char **)o->to;
    a.nto = o->nto;
    a.private_ = o->dm;
    if (strcmp(o->pos[1], "-") == 0) {
        int r = read_stdin_all(&in);
        if (r == -2) { buf_free(&in); say("the text on stdin is longer than 1 MiB"); return EXIT_USAGE; }
        if (r < 0) { buf_free(&in); say("cannot read stdin"); return EXIT_LOCAL; }
        a.text = in.p ? in.p : (const unsigned char *)"";
        a.text_len = in.len;
    } else if (o->npos == 2) {
        a.text = (const unsigned char *)o->pos[1];
        a.text_len = strlen(o->pos[1]);
    } else {
        /* several words (the text not quoted): joined with one space, as a shell would have passed them quoted */
        for (size_t i = 1; i < o->npos; i++)
            if ((i > 1 && buf_addc(&in, ' ') < 0) || buf_adds(&in, o->pos[i]) < 0) {
                buf_free(&in);
                say("the text is longer than 1 MiB");
                return EXIT_USAGE;
            }
        a.text = in.p;
        a.text_len = in.len;
    }
    rc = do_send(&a, NULL);
    buf_free(&in);
    return rc;
}

static int cmd_react(const struct opts *o) {
    if (o->npos != 3) return usage_error("react takes ROOM MSG_ID REACTION");
    int rc = configure();
    if (rc) return rc;
    struct buf t = buf_new(4096);
    if (buf_adds(&t, "/react ") | buf_adds(&t, o->pos[2])) { buf_free(&t); return usage_error("the reaction is too long"); }
    struct send_args a;
    memset(&a, 0, sizeof a);
    a.room = o->pos[0];
    a.re = o->pos[1];
    a.text = t.p;
    a.text_len = t.len;
    rc = do_send(&a, NULL);
    buf_free(&t);
    return rc;
}

static int cmd_command(const struct opts *o, const char *text, int detail) {
    if (o->npos != 0) return usage_error("this command takes no argument but --room");
    int rc = configure();
    if (rc) return rc;
    struct send_args a;
    memset(&a, 0, sizeof a);
    a.room = o->room;
    a.text = (const unsigned char *)text;
    a.text_len = strlen(text);
    if (!detail) return do_send(&a, NULL);
    struct buf d = buf_new(MAX_ANSWER);
    rc = do_send(&a, &d);
    if (rc == EXIT_DONE && out_line(d.p, d.len) < 0) rc = EXIT_LOCAL;
    buf_free(&d);
    return rc;
}

static int cmd_receive(const struct opts *o) {
    if (o->npos != 0) return usage_error("receive takes no argument");
    int rc = configure();
    if (rc) return rc;
    struct answer ans;
    size_t a0, a1, count;
    rc = get_receive((int)clamp_wait(o->wait, 0), o->redeliver, &ans, &a0, &a1, 0);
    if (rc) return rc;
    struct buf acks = buf_new(MAX_REQUEST_BODY);
    struct print_ctx c = {o->ack ? &acks : NULL, 0, 0};
    (void)each_message(ans.body.p, ans.body.len, print_item, &c, &count);
    buf_free(&ans.body);
    if (c.bad == 1) { buf_free(&acks); say("stdout is closed: nothing acknowledged"); return EXIT_LOCAL; }
    if (c.bad == 2) { buf_free(&acks); say("an item's room, msg_id or delivery is not plain text: not acknowledged"); return EXIT_LOCAL; }
    if (o->ack && c.n) {
        rc = post_acks(&acks, 0, 0);
        if (rc == EXIT_DONE) say("acknowledged %zu", c.n);
    }
    buf_free(&acks);
    return rc;
}

/* "ROOM:MSG_ID[:DELIVERY]" (a message's delivery is its own id). */
static int parse_ack_ref(const char *ref, char *room, char *msg, char *del) {
    const char *c1 = strchr(ref, ':');
    if (!c1 || c1 == ref) return -1;
    const char *rest = c1 + 1;
    const char *c2 = strchr(rest, ':');
    size_t rl = (size_t)(c1 - ref), ml = c2 ? (size_t)(c2 - rest) : strlen(rest), dl = c2 ? strlen(c2 + 1) : 0;
    if (ml == 0 || rl > MAX_ID || ml > MAX_ID || dl > MAX_ID) return -1;
    memcpy(room, ref, rl); room[rl] = 0;
    memcpy(msg, rest, ml); msg[ml] = 0;
    if (dl) { memcpy(del, c2 + 1, dl); del[dl] = 0; }
    else { memcpy(del, msg, ml + 1); }
    for (const char *s = ref; *s; s++)
        if ((unsigned char)*s < 0x20 || (unsigned char)*s > 0x7E) return -1;
    return 0;
}

static int cmd_ack(const struct opts *o) {
    if (o->npos == 0) return usage_error("ack takes ROOM:MSG_ID[:DELIVERY] ..., or -");
    int from_stdin = o->npos == 1 && strcmp(o->pos[0], "-") == 0;
    struct buf acks = buf_new(MAX_REQUEST_BODY);
    size_t n = 0;
    if (!from_stdin) {
        for (size_t i = 0; i < o->npos; i++) {
            char room[MAX_ID + 1], msg[MAX_ID + 1], del[MAX_ID + 1];
            if (parse_ack_ref(o->pos[i], room, msg, del) < 0) {
                buf_free(&acks);
                return usage_error("ack takes ROOM:MSG_ID[:DELIVERY] (DELIVERY is the item's delivery), or -");
            }
            if (add_ack(&acks, n == 0, room, msg, del) < 0) { buf_free(&acks); return usage_error("too much to acknowledge"); }
            n++;
        }
    }
    int rc = configure();
    if (rc) { buf_free(&acks); return rc; }
    if (from_stdin) {
        struct buf line = buf_new(MAX_ACK_LINE);
        unsigned char chunk[65536];
        int eof = 0;
        while (!eof) {
            ssize_t r = read(0, chunk, sizeof chunk);
            if (r < 0 && errno == EINTR) continue;
            if (r < 0) { buf_free(&line); buf_free(&acks); say("cannot read stdin"); return EXIT_LOCAL; }
            size_t len = r > 0 ? (size_t)r : 0;
            if (r == 0) { eof = 1; chunk[0] = '\n'; len = 1; }
            for (size_t k = 0; k < len; k++) {
                if (chunk[k] != '\n') {
                    if (buf_addc(&line, chunk[k]) < 0) { buf_free(&line); buf_free(&acks); say("a line on stdin is longer than 32 MiB"); return EXIT_USAGE; }
                    continue;
                }
                size_t a, b;
                if (skip_ws(line.p, line.len, 0) == line.len) { line.len = 0; continue; }
                if (scan_document(line.p, line.len, &a, &b) < 0 || line.p[a] != '{') {
                    buf_free(&line); buf_free(&acks);
                    say("not a JSON line (ack - reads the lines receive printed)");
                    return EXIT_USAGE;
                }
                if (add_ack_item(&acks, n == 0, line.p, a, b) < 0) {
                    buf_free(&line); buf_free(&acks);
                    say("a line's room, msg_id or delivery is not plain text");
                    return EXIT_USAGE;
                }
                n++;
                line.len = 0;
            }
        }
        buf_free(&line);
    }
    if (n == 0) {
        buf_free(&acks);
        return out_line((const unsigned char *)"{\"acked\":0}", 11) < 0 ? EXIT_LOCAL : EXIT_DONE;
    }
    rc = post_acks(&acks, 1, 0);
    buf_free(&acks);
    return rc;
}

struct listen_ctx {
    int stopped; /* stdout is gone */
    int failed;  /* an acknowledgement failed for good: its code */
};

static int listen_item(void *vctx, const unsigned char *s, size_t a, size_t b) {
    struct listen_ctx *c = vctx;
    struct buf line = buf_new(MAX_ANSWER);
    int bad = json_compact(&line, s, a, b) < 0 || out_line(line.p, line.len) < 0;
    buf_free(&line);
    if (bad) { c->stopped = 1; return 1; }
    struct buf acks = buf_new(4 * KIB);
    if (add_ack_item(&acks, 1, s, a, b) < 0) {
        buf_free(&acks);
        say("an item's ids are not plain text: not acknowledged (it will come again)");
        return 0;
    }
    int rc = post_acks(&acks, 0, 1);
    buf_free(&acks);
    if (rc == EXIT_AWAY) say("could not acknowledge an item (%s); it will come again", g_why);
    else if (rc != EXIT_DONE) { c->failed = rc; return 1; }
    return 0;
}

static int cmd_listen(const struct opts *o) {
    if (o->npos != 0) return usage_error("listen takes no argument");
    int rc = configure();
    if (rc) return rc;
    int wait = (int)clamp_wait(o->wait, 25);
    say("listening at %s (Ctrl-C stops)", g_chat_base);
    unsigned backoff = 1;
    int first = 1;
    for (;;) {
        struct answer ans;
        size_t a0, a1, count;
        rc = get_receive(wait, first, &ans, &a0, &a1, 1);
        if (rc == EXIT_AWAY) {
            say("%s; trying again in %u s", g_why, backoff);
            sleep_s(backoff);
            backoff = backoff * 2 > 30 ? 30 : backoff * 2;
            continue;
        }
        if (rc) return rc;
        first = 0;
        backoff = 1;
        struct listen_ctx c = {0, 0};
        (void)each_message(ans.body.p, ans.body.len, listen_item, &c, &count);
        buf_free(&ans.body);
        if (c.stopped) { say("stdout is closed: stopping (the rest is not acknowledged)"); return EXIT_LOCAL; }
        if (c.failed) return c.failed;
        if (o->once && count) return EXIT_DONE;
    }
}

static int cmd_file_send(const struct opts *o) {
    if (o->npos < 2 || o->npos > 3) return usage_error("file send takes ROOM PATH [TEXT]");
    int rc = configure();
    if (rc) return rc;
    const char *path = o->pos[1];
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { say("cannot read %s: %s", path, strerror(errno)); return EXIT_LOCAL; }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) { close(fd); say("not a regular file: %s", path); return EXIT_USAGE; }
    if (st.st_size <= 0 || (unsigned long long)st.st_size > MAX_FILE) { close(fd); say("a file is sent when it is 1 byte to 20 MB"); return EXIT_USAGE; }
    size_t size = (size_t)st.st_size;
    struct buf data = buf_new(MAX_FILE);
    if (buf_reserve(&data, size) < 0) { close(fd); say("out of memory"); return EXIT_LOCAL; }
    while (data.len < size) {
        ssize_t r = read(fd, data.p + data.len, size - data.len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        data.len += (size_t)r;
    }
    unsigned char extra;
    ssize_t more = read(fd, &extra, 1);
    close(fd);
    if (data.len != size || more > 0) { buf_free(&data); say("%s changed while it was read: not sent", path); return EXIT_LOCAL; }
    char name[CLEAN_MAX + 1];
    clean_name(path, name);
    struct send_args a;
    memset(&a, 0, sizeof a);
    a.room = o->pos[0];
    a.re = o->re;
    a.text = (const unsigned char *)(o->npos == 3 ? o->pos[2] : "");
    a.text_len = strlen((const char *)a.text);
    a.att_name = name;
    a.att_data = data.p;
    a.att_len = data.len;
    rc = do_send(&a, NULL);
    buf_free(&data);
    return rc;
}

static int pct_encode(struct buf *out, const char *s) {
    static const char hex[] = "0123456789ABCDEF";
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        int keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
        int e = keep ? buf_addc(out, c) : (buf_addc(out, '%') | buf_addc(out, (unsigned char)hex[c >> 4]) | buf_addc(out, (unsigned char)hex[c & 15]));
        if (e) return -1;
    }
    return 0;
}

/* REF: an attachment's url (this server's only), "/files/ID/NAME", or ID. */
static int file_ref(const char *ref, char id[65], const char **url_name) {
    const char *path = ref;
    if (strstr(ref, "://")) {
        struct url u;
        int r = url_parse(ref, &u, NULL, 0, NULL);
        if (r != URL_OK || !ascii_ieq(u.host, strlen(u.host), g_chat.host, strlen(g_chat.host)) || u.port != g_chat.port) {
            say("that address is not this chat server's; the token goes nowhere else");
            return EXIT_USAGE;
        }
        path = ref + u.path_at;
    }
    const char *idp, *ide;
    if (strncmp(path, "/files/", 7) == 0) {
        idp = path + 7;
        ide = strchr(idp, '/');
        if (!ide) { ide = idp + strlen(idp); *url_name = ""; }
        else *url_name = ide + 1;
    } else if (!strchr(path, '/') && path == ref) {
        idp = path;
        ide = path + strlen(path);
        *url_name = "";
    } else {
        say("give an attachment's url (/files/ID/NAME) or its id");
        return EXIT_USAGE;
    }
    size_t l = (size_t)(ide - idp);
    if (l == 0 || l > 64) { say("an attachment id is hex digits"); return EXIT_USAGE; }
    for (size_t i = 0; i < l; i++)
        if (!((idp[i] >= '0' && idp[i] <= '9') || (idp[i] >= 'a' && idp[i] <= 'f'))) { say("an attachment id is hex digits"); return EXIT_USAGE; }
    memcpy(id, idp, l);
    id[l] = 0;
    if (strchr(*url_name, '?') || strchr(*url_name, '#')) { say("an attachment's url has no query"); return EXIT_USAGE; }
    return EXIT_DONE;
}

static int cmd_file_get(const struct opts *o) {
    if (o->npos != 1) return usage_error("file get takes URL-OR-ID");
    int rc = configure();
    if (rc) return rc;
    char id[65];
    const char *url_name = "";
    if ((rc = file_ref(o->pos[0], id, &url_name))) return rc;
    char safe[CLEAN_MAX + 1];
    clean_name(o->name ? o->name : (*url_name ? url_name : id), safe);
    const char *folder = o->out ? o->out : ".";
    int dirfd = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) { say("no such folder: %s", folder); return EXIT_USAGE; }
    char *real = realpath(folder, NULL);
    if (!real) { close(dirfd); say("no such folder: %s", folder); return EXIT_USAGE; }
    struct buf dest = buf_new(64 * KIB);
    int bad = buf_adds(&dest, real) | buf_adds(&dest, strcmp(real, "/") == 0 ? "" : "/") | buf_adds(&dest, safe);
    free(real);
    struct buf line = buf_new(128 * KIB);
    bad |= buf_adds(&line, "{\"id\":") | json_strz(&line, id) | buf_adds(&line, ",\"path\":");
    if (bad || json_str(&line, dest.p, dest.len) != ESC_OK) {
        close(dirfd); buf_free(&dest); buf_free(&line);
        say("the folder's path is not UTF-8");
        return EXIT_USAGE;
    }
    struct stat st;
    if (fstatat(dirfd, safe, &st, AT_SYMLINK_NOFOLLOW) == 0) {
        close(dirfd); buf_free(&line);
        say("refused: %.*s exists", (int)(dest.len > 4096 ? 4096 : dest.len), (const char *)dest.p);
        buf_free(&dest);
        return EXIT_LOCAL;
    }
    struct buf path = buf_new(4 * KIB);
    if (buf_adds(&path, "/files/") | buf_adds(&path, id) | buf_addc(&path, '/') | pct_encode(&path, *url_name ? url_name : safe) |
        buf_addc(&path, 0)) {
        close(dirfd); buf_free(&dest); buf_free(&line); buf_free(&path);
        say("the attachment's name is too long");
        return EXIT_USAGE;
    }
    struct answer ans;
    rc = http_call("GET", (const char *)path.p, NULL, 0, FILE_TIMEOUT, MAX_FILE, &ans);
    buf_free(&path);
    if (rc != EXIT_DONE) {
        if (rc == EXIT_LOCAL && strstr(g_why, "larger than")) say("the file is larger than 20 MB; not written");
        else say("%s", g_why);
        close(dirfd); buf_free(&dest); buf_free(&line);
        return rc;
    }
    if (ans.status == 404) {
        buf_free(&ans.body); close(dirfd); buf_free(&dest); buf_free(&line);
        say("no such attachment, or not one you may read");
        return EXIT_REFUSED;
    }
    if (ans.status != 200) {
        rc = answer_failure(&ans);
        buf_free(&ans.body); close(dirfd); buf_free(&dest); buf_free(&line);
        return rc;
    }
    int fd = openat(dirfd, safe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        int e = errno;
        buf_free(&ans.body); close(dirfd); buf_free(&line);
        if (e == EEXIST) say("refused: %.*s exists", (int)(dest.len > 4096 ? 4096 : dest.len), (const char *)dest.p);
        else say("cannot write %.*s: %s", (int)(dest.len > 4096 ? 4096 : dest.len), (const char *)dest.p, strerror(e));
        buf_free(&dest);
        return EXIT_LOCAL;
    }
    size_t off = 0;
    int werr = 0;
    while (off < ans.body.len) {
        ssize_t w = write(fd, ans.body.p + off, ans.body.len - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { werr = w < 0 ? errno : EIO; break; }
        off += (size_t)w;
    }
    if (close(fd) < 0 && !werr) werr = errno;
    if (werr) {
        unlinkat(dirfd, safe, 0);
        buf_free(&ans.body); close(dirfd); buf_free(&line);
        say("cannot write %.*s: %s (the partial file is removed)", (int)(dest.len > 4096 ? 4096 : dest.len), (const char *)dest.p, strerror(werr));
        buf_free(&dest);
        return EXIT_LOCAL;
    }
    close(dirfd);
    bad = buf_adds(&line, ",\"size\":") | buf_addu(&line, ans.body.len) | buf_adds(&line, ",\"type\":") | json_strz(&line, ans.type) |
          buf_addc(&line, '}');
    buf_free(&ans.body);
    buf_free(&dest);
    rc = bad || out_line(line.p, line.len) < 0 ? EXIT_LOCAL : EXIT_DONE;
    buf_free(&line);
    return rc;
}

static int run(int argc, char **argv) {
    if (argc < 2) { fputs(USAGE, stderr); return EXIT_USAGE; }
    const char *cmd = argv[1];
    if (strcmp(cmd, "--version") == 0 || strcmp(cmd, "-V") == 0) {
        fputs("dozchat " DOZCHAT_VERSION "\n", stdout);
        return fflush(stdout) == 0 ? EXIT_DONE : EXIT_LOCAL;
    }
    if (strcmp(cmd, "--help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "help") == 0) {
        fputs(USAGE, stdout);
        return fflush(stdout) == 0 ? EXIT_DONE : EXIT_LOCAL;
    }
    struct opts o;
    int rc;
    if (strcmp(cmd, "file") == 0) {
        if (argc < 3 || (strcmp(argv[2], "get") != 0 && strcmp(argv[2], "send") != 0)) return usage_error("file get | file send");
        int get = strcmp(argv[2], "get") == 0;
        if ((rc = parse_opts(argc, argv, 3, get ? " --out --name " : " --re ", &o))) return rc;
        if (o.help) { fputs(USAGE, stdout); return EXIT_DONE; }
        return get ? cmd_file_get(&o) : cmd_file_send(&o);
    }
    const char *allowed = NULL;
    if (strcmp(cmd, "send") == 0) allowed = " --re --to --dm ";
    else if (strcmp(cmd, "react") == 0) allowed = " ";
    else if (strcmp(cmd, "receive") == 0) allowed = " --wait --ack --redeliver ";
    else if (strcmp(cmd, "ack") == 0) allowed = " ";
    else if (strcmp(cmd, "listen") == 0) allowed = " --wait --once ";
    else if (strcmp(cmd, "rooms") == 0 || strcmp(cmd, "protocol") == 0) allowed = " --room ";
    else return usage_error("unknown command");
    if ((rc = parse_opts(argc, argv, 2, allowed, &o))) return rc;
    if (o.help) { fputs(USAGE, stdout); return EXIT_DONE; }
    if (strcmp(cmd, "send") == 0) return cmd_send(&o);
    if (strcmp(cmd, "react") == 0) return cmd_react(&o);
    if (strcmp(cmd, "receive") == 0) return cmd_receive(&o);
    if (strcmp(cmd, "ack") == 0) return cmd_ack(&o);
    if (strcmp(cmd, "listen") == 0) return cmd_listen(&o);
    if (strcmp(cmd, "rooms") == 0) return cmd_command(&o, "/rooms", 0);
    return cmd_command(&o, "/protocol", 1);
}

#ifndef DOZCHAT_NO_MAIN
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_interrupt;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    int rc = run(argc, argv);
    wipe_secrets();
    if (fflush(stdout) != 0 && rc == EXIT_DONE) rc = EXIT_LOCAL;
    return rc;
}
#endif
