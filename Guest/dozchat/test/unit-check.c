/*
 * unit-check.c — dozchat's parts against fixed vectors, then a seeded fuzz of the escaper, the scanner and the answer
 * head. Built with AddressSanitizer and UndefinedBehaviorSanitizer (-fno-sanitize-recover=all) by `make dozchat-check`
 * and by Tests/DozableChatTests/DozchatUnitTests.swift (so `make test` and CI run it).
 *
 *     unit-check [--vectors clean-name.tsv] [--iterations N] [--seed S]   every check; prints "ok dozchat-check: …"
 *     unit-check escape FILE                                               FILE: one string per line, in hex; prints each
 *                                                                          as json_str() writes it, or "!" when refused
 */
#define DOZCHAT_NO_MAIN 1
#include "../dozchat.c"

static int failures, checks;

#define CHECK(cond, ...)                                                                                              \
    do {                                                                                                              \
        checks++;                                                                                                     \
        if (!(cond)) {                                                                                                \
            failures++;                                                                                               \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                                      \
            fprintf(stderr, __VA_ARGS__);                                                                             \
            fputc('\n', stderr);                                                                                      \
        }                                                                                                             \
    } while (0)

/* An exact-size heap copy, so the sanitizer sees any read past the end. */
static unsigned char *dup_exact(const void *p, size_t n) {
    unsigned char *q = malloc(n ? n : 1);
    if (!q) abort();
    if (n) memcpy(q, p, n);
    return q;
}

static int esc(const unsigned char *s, size_t n, struct buf *out) {
    out->len = 0;
    unsigned char *c = dup_exact(s, n);
    int r = json_str(out, c, n);
    free(c);
    return r;
}

static int esc_is(const char *in, size_t n, const char *want) {
    struct buf b = buf_new(1 << 20);
    int r = esc((const unsigned char *)in, n, &b);
    int ok = r == ESC_OK && b.len == strlen(want) && memcmp(b.p, want, b.len) == 0;
    buf_free(&b);
    return ok;
}

static int esc_refused(const char *in, size_t n) {
    struct buf b = buf_new(1 << 20);
    int r = esc((const unsigned char *)in, n, &b);
    buf_free(&b);
    return r == ESC_INVALID;
}

/* An independent UTF-8 check (code points decoded, then judged), for the fuzz. */
static int ref_utf8_valid(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned c = s[i], need, cp;
        if (c < 0x80) { i++; continue; }
        if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
        else return 0;
        if (n - i <= need) return 0;
        for (unsigned k = 1; k <= need; k++) {
            if ((s[i + k] & 0xC0) != 0x80) return 0;
            cp = (cp << 6) | (s[i + k] & 0x3F);
        }
        unsigned min = need == 1 ? 0x80 : need == 2 ? 0x800 : 0x10000;
        if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
        i += need + 1;
    }
    return 1;
}

static int compact_is(const char *in, const char *want) {
    size_t n = strlen(in), a, b;
    unsigned char *c = dup_exact(in, n);
    int ok = 0;
    if (scan_document(c, n, &a, &b) == 0) {
        struct buf o = buf_new(1 << 20);
        if (json_compact(&o, c, a, b) == 0) ok = o.len == strlen(want) && memcmp(o.p, want, o.len) == 0;
        buf_free(&o);
    }
    free(c);
    return ok;
}

static int scans(const char *in, size_t n) {
    size_t a, b;
    unsigned char *c = dup_exact(in, n);
    int r = scan_document(c, n, &a, &b);
    free(c);
    return r == 0;
}

static int string_is(const char *doc, const char *key, const char *want, size_t wantn) {
    size_t n = strlen(doc), a, b;
    unsigned char *c = dup_exact(doc, n);
    int ok = 0;
    if (scan_document(c, n, &a, &b) == 0) {
        struct buf v = buf_new(4096);
        int r = obj_string(c, a, b, key, &v);
        ok = want ? (r == FIND_FOUND && v.len == wantn && memcmp(v.p, want, wantn) == 0) : r != FIND_FOUND;
        buf_free(&v);
    }
    free(c);
    return ok;
}

struct collect {
    char ids[8][MAX_ID + 1];
    size_t n;
};

static int collect_id(void *vctx, const unsigned char *s, size_t a, size_t b) {
    struct collect *c = vctx;
    if (c->n < 8 && ack_id(s, a, b, "msg_id", c->ids[c->n]) == 0) c->n++;
    return 0;
}

static void check_escaper(void) {
    char in[2], want[16];
    for (int c = 0; c < 0x20; c++) {
        in[0] = (char)c;
        const char *w = c == '\n' ? "\"\\n\"" : c == '\r' ? "\"\\r\"" : c == '\t' ? "\"\\t\"" : NULL;
        if (!w) {
            snprintf(want, sizeof want, "\"\\u00%02x\"", c);
            w = want;
        }
        CHECK(esc_is(in, 1, w), "control byte %02x escaped as %s", c, w);
    }
    CHECK(esc_is("\x7f", 1, "\"\\u007f\""), "DEL escaped");
    CHECK(esc_is("\"", 1, "\"\\\"\""), "a quote escaped");
    CHECK(esc_is("\\", 1, "\"\\\\\""), "a backslash escaped");
    CHECK(esc_is("", 0, "\"\""), "the empty string");
    CHECK(esc_is("hello /world/ <ok>", 18, "\"hello /world/ <ok>\""), "plain text kept, / not escaped");
    CHECK(esc_is("\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80", 9, "\"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\""), "valid UTF-8 kept as it is");
    CHECK(esc_is("\xef\xbf\xbf\xf4\x8f\xbf\xbf\xed\x9f\xbf", 10, "\"\xef\xbf\xbf\xf4\x8f\xbf\xbf\xed\x9f\xbf\""), "U+FFFF, U+10FFFF, U+D7FF kept");
    const struct { const char *s; size_t n; const char *what; } bad[] = {
        {"\x80", 1, "a lone continuation byte"}, {"\xc0\xaf", 2, "an overlong /"}, {"\xc1\xbf", 2, "an overlong 2-byte"},
        {"\xe0\x80\xaf", 3, "an overlong 3-byte"}, {"\xf0\x80\x80\xaf", 4, "an overlong 4-byte"},
        {"\xed\xa0\x80", 3, "a high surrogate"}, {"\xed\xbf\xbf", 3, "a low surrogate"},
        {"\xf4\x90\x80\x80", 4, "above U+10FFFF"}, {"\xf5\x80\x80\x80", 4, "an F5 lead"}, {"\xff", 1, "FF"}, {"\xfe", 1, "FE"},
        {"\xe2\x82", 2, "a cut 3-byte sequence"}, {"\xf0\x9f\x98", 3, "a cut 4-byte sequence"}, {"a\xc3", 2, "a cut 2-byte at the end"},
        {"\xc3\x28", 2, "a bad continuation"},
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) CHECK(esc_refused(bad[i].s, bad[i].n), "refused: %s", bad[i].what);
    /* The maximum is hard. */
    struct buf small = buf_new(5);
    CHECK(json_str(&small, (const unsigned char *)"abcdef", 6) == ESC_TOO_BIG, "past the buffer's maximum: refused");
    buf_free(&small);
}

static void check_scanner(void) {
    CHECK(compact_is(" { \"a\" : [ 1 , 2 , { \"b\" : \"x y\" } ] , \"c\" : null } ", "{\"a\":[1,2,{\"b\":\"x y\"}],\"c\":null}"),
          "whitespace outside strings removed, inside kept");
    CHECK(compact_is("{\"s\":\"a\\\" }\\\\ \\n\"}", "{\"s\":\"a\\\" }\\\\ \\n\"}"), "escaped quotes and backslashes keep the string open");
    CHECK(compact_is("[true,false,null,-1.5e+3]", "[true,false,null,-1.5e+3]"), "literals and numbers");
    CHECK(!scans("{\"a\":\"open", 10), "an unclosed string");
    CHECK(!scans("{\"a\":\"x\x01y\"}", 11), "a control character inside a string");
    CHECK(!scans("{\"a\":[1,2}", 10), "unbalanced brackets");
    CHECK(!scans("{\"a\":1}}", 8), "a second value");
    CHECK(!scans("{\"a\" 1}", 7), "a missing colon");
    CHECK(!scans("{\"a\":\"\\x\"}", 10), "a bad escape");
    CHECK(!scans("{\"a\":\"\\u12g4\"}", 14), "a bad \\u escape");
    CHECK(!scans("{\"a\":\"\\u12\"}", 12), "a cut \\u escape");
    CHECK(!scans("{1:2}", 5), "a key that is not a string");
    CHECK(!scans("", 0) && !scans("   ", 3), "nothing");
    CHECK(!scans("{\"a\":tru}", 9), "a cut literal");
    /* Depth: 64 nested arrays scan, 65 do not. */
    char deep[200];
    for (int d = 63; d <= 65; d++) {
        size_t o = 0;
        for (int i = 0; i < d; i++) deep[o++] = '[';
        for (int i = 0; i < d; i++) deep[o++] = ']';
        CHECK(scans(deep, o) == (d <= MAX_DEPTH), "depth %d %s", d, d <= MAX_DEPTH ? "scans" : "is refused");
    }
    /* Strings decoded: every escape, a surrogate pair; a lone surrogate refused. */
    CHECK(string_is("{\"k\":\"a\\u00e9\\ud83d\\ude00\\n\\t\\/\\\\\\\"\"}", "k", "a\xc3\xa9\xf0\x9f\x98\x80\n\t/\\\"", 12), "escapes decoded");
    CHECK(string_is("{\"k\":\"\\ud83d\"}", "k", NULL, 0), "a lone high surrogate refused");
    CHECK(string_is("{\"k\":\"\\ude00\"}", "k", NULL, 0), "a lone low surrogate refused");
    CHECK(string_is("{\"k\":\"\\ud83d\\u0041\"}", "k", NULL, 0), "a high surrogate followed by a letter refused");
    CHECK(string_is("{\"k\":1,\"k\":\"last\"}", "k", "last", 4), "the last key wins");
    CHECK(string_is("{\"k\":{\"error\":\"inner\"}}", "error", NULL, 0), "only top-level keys are found");
    CHECK(string_is("{\"k\":5}", "k", NULL, 0), "a key whose value is not a string is not taken");
    CHECK(string_is("{\"\\u0065rror\":\"esc\"}", "error", "esc", 3), "an escaped key matches");
    /* The messages array. */
    const char *recv = "{\"messages\":[{\"room\":\"room1\",\"msg_id\":\"m1\",\"delivery\":\"m1\",\"message\":{\"content\":\"[x]\"}},"
                       " {\"room\":\"room1\",\"msg_id\":\"m2\",\"x\":[\"]\",\"{\"]}],\"protocol_version\":\"abc\"}";
    unsigned char *c = dup_exact(recv, strlen(recv));
    struct collect col;
    memset(&col, 0, sizeof col);
    size_t count = 0;
    CHECK(each_message(c, strlen(recv), collect_id, &col, &count) == 0 && count == 2 && col.n == 2 &&
              strcmp(col.ids[0], "m1") == 0 && strcmp(col.ids[1], "m2") == 0,
          "the messages array's two items and their ids (count %zu)", count);
    free(c);
    const char *none = "{\"messages\":[]}";
    c = dup_exact(none, strlen(none));
    CHECK(each_message(c, strlen(none), NULL, NULL, &count) == 0 && count == 0, "an empty messages array");
    free(c);
    const char *nolist = "{\"message\":[]}";
    c = dup_exact(nolist, strlen(nolist));
    CHECK(each_message(c, strlen(nolist), NULL, NULL, &count) != 0, "no messages array is an error");
    free(c);
    /* An id that is not plain text is not given back. */
    const char *ctl = "{\"msg_id\":\"a\\nb\"}";
    c = dup_exact(ctl, strlen(ctl));
    char id[MAX_ID + 1];
    CHECK(ack_id(c, 0, strlen(ctl), "msg_id", id) < 0, "a control character in an id refused");
    free(c);
    char longdoc[400];
    size_t o = (size_t)snprintf(longdoc, sizeof longdoc, "{\"msg_id\":\"");
    for (int i = 0; i < 257; i++) longdoc[o++] = 'a';
    longdoc[o++] = '"'; longdoc[o++] = '}';
    c = dup_exact(longdoc, o);
    CHECK(ack_id(c, 0, o, "msg_id", id) < 0, "an id of 257 bytes refused");
    free(c);
    /* Truncated at every offset: a strict prefix of an object is never a document. */
    const char *docs[] = {recv, "{\"state\":\"queued\",\"msg_id\":\"6f\\u00e9\",\"detail\":\"a \\\"b\\\"\"}", "{\"a\":[[[{\"b\":[1,{}]}]]]}"};
    for (size_t d = 0; d < 3; d++) {
        size_t n = strlen(docs[d]);
        int bad = 0;
        for (size_t cut = 0; cut < n; cut++) {
            unsigned char *p = dup_exact(docs[d], cut);
            size_t a, b;
            if (scan_document(p, cut, &a, &b) == 0) bad++;
            struct buf v = buf_new(4096);
            if (cut > 0 && p[0] == '{') (void)obj_string(p, 0, cut, "msg_id", &v);
            buf_free(&v);
            (void)each_message(p, cut, NULL, NULL, &count);
            free(p);
        }
        CHECK(bad == 0, "document %zu: %d of its cut prefixes scanned as whole", d, bad);
        CHECK(scans(docs[d], n), "document %zu scans whole", d);
    }
}

static void check_base64(void) {
    const char *in[] = {"", "f", "fo", "foo", "foob", "fooba", "foobar"};
    const char *out[] = {"", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"};
    for (size_t i = 0; i < 7; i++) {
        struct buf b = buf_new(64);
        unsigned char *c = dup_exact(in[i], strlen(in[i]));
        int r = base64_append(&b, c, strlen(in[i]));
        CHECK(r == 0 && b.len == strlen(out[i]) && (b.len == 0 || memcmp(b.p, out[i], b.len) == 0), "base64(\"%s\") = %s", in[i], out[i]);
        free(c);
        buf_free(&b);
    }
    unsigned char all[256];
    for (int i = 0; i < 256; i++) all[i] = (unsigned char)i;
    struct buf b = buf_new(1024);
    CHECK(base64_append(&b, all, 256) == 0 && b.len == 344 && memcmp(b.p + 340, "/w==", 4) == 0, "base64 of every byte");
    buf_free(&b);
    size_t sz;
    CHECK(base64_size(SIZE_MAX, &sz) < 0 && base64_size(SIZE_MAX / 4 * 3 + 1, &sz) < 0, "an overflowing size refused");
    CHECK(base64_size(3, &sz) == 0 && sz == 4 && base64_size(0, &sz) == 0 && sz == 0, "sizes");
    struct buf tiny = buf_new(7);
    CHECK(base64_append(&tiny, (const unsigned char *)"abcdef", 6) < 0, "past the maximum: refused");
    buf_free(&tiny);
}

static void check_clean_name(const char *file) {
    FILE *f = fopen(file, "r");
    CHECK(f != NULL, "the shared vectors %s", file);
    if (!f) return;
    char line[4096];
    int n = 0;
    while (fgets(line, sizeof line, f)) {
        size_t l = strlen(line);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        if (l == 0 || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        CHECK(tab != NULL, "a vector line has a tab: %s", line);
        if (!tab) continue;
        *tab = 0;
        char got[CLEAN_MAX + 1];
        char *in = (char *)dup_exact(line, strlen(line) + 1);
        clean_name(in, got);
        free(in);
        CHECK(strcmp(got, tab + 1) == 0, "clean_name(\"%s\") = \"%s\", want \"%s\"", line, got, tab + 1);
        n++;
    }
    fclose(f);
    CHECK(n >= 20, "the shared vectors: %d", n);
    char got[CLEAN_MAX + 1];
    clean_name("a\xff" "b", got);
    CHECK(strcmp(got, "a_b") == 0, "an invalid byte is one _ (%s)", got);
    char big[5000];
    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = 0;
    clean_name(big, got);
    CHECK(strlen(got) == CLEAN_MAX, "cut to 120 bytes");
}

static void check_urls(void) {
    struct url u;
    CHECK(chat_url_parse("http://host.dozable.internal:8790", &u) == URL_OK && strcmp(u.host, "host.dozable.internal") == 0 &&
              u.port == 8790 && strcmp(u.authority, "host.dozable.internal:8790") == 0, "the default");
    CHECK(chat_url_parse("http://127.0.0.1:8790/", &u) == URL_OK && u.port == 8790, "a trailing slash");
    CHECK(chat_url_parse("HTTP://Example.Test", &u) == URL_OK && u.port == 80 && strcmp(u.authority, "Example.Test") == 0, "port 80 left out of Host");
    CHECK(chat_url_parse("http://[::1]:8790", &u) == URL_OK && strcmp(u.host, "::1") == 0 && strcmp(u.authority, "[::1]:8790") == 0, "an IPv6 literal");
    CHECK(chat_url_parse("https://x.test", &u) == URL_HTTPS, "https refused");
    CHECK(chat_url_parse("http://u:p@x.test", &u) == URL_USERINFO, "a user and password refused");
    CHECK(chat_url_parse("http://x.test/path", &u) == URL_BAD, "a path refused");
    CHECK(chat_url_parse("http://x.test?q=1", &u) == URL_BAD, "a query refused");
    CHECK(chat_url_parse("http://x.test:0", &u) == URL_BAD && chat_url_parse("http://x.test:65536", &u) == URL_BAD &&
              chat_url_parse("http://x.test:", &u) == URL_BAD && chat_url_parse("http://x.test:8a", &u) == URL_BAD, "bad ports refused");
    CHECK(chat_url_parse("http://", &u) == URL_BAD && chat_url_parse("x.test:8790", &u) == URL_BAD && chat_url_parse("ftp://x", &u) == URL_BAD,
          "no host, no scheme, another scheme");
    CHECK(chat_url_parse("http://a b.test", &u) == URL_BAD && chat_url_parse("http://a\r\nb.test", &u) == URL_BAD, "spaces and line breaks refused");
    char ui[128];
    size_t uil;
    CHECK(url_parse("http://doz:pa%3Ass@127.0.0.1:41000", &u, ui, sizeof ui, &uil) == URL_OK && uil == 11 && strcmp(ui, "doz:pa%3Ass") == 0 &&
              u.port == 41000, "a proxy's user and password");
    char dec[64];
    size_t dn;
    CHECK(pct_decode("pa%3Ass", 7, dec, sizeof dec, &dn) == 0 && dn == 5 && strcmp(dec, "pa:ss") == 0, "percent-decoded");
    CHECK(pct_decode("a%2", 3, dec, sizeof dec, &dn) < 0 && pct_decode("a%0a", 4, dec, sizeof dec, &dn) < 0, "a cut escape and a line break refused");
    CHECK(no_proxy_matches("localhost,127.0.0.1,::1", "127.0.0.1") && !no_proxy_matches("localhost,127.0.0.1,::1", "host.dozable.internal"),
          "NO_PROXY: exact names");
    CHECK(no_proxy_matches(" Host.Dozable.Internal ", "host.dozable.internal") && no_proxy_matches("a,*", "x") && no_proxy_matches("[::1]", "::1"),
          "NO_PROXY: case, spaces, *, brackets");
    CHECK(!no_proxy_matches(".dozable.internal", "host.dozable.internal") && !no_proxy_matches(NULL, "x") && !no_proxy_matches("", "x"),
          "NO_PROXY: no suffix match, nothing");
    char room[MAX_ID + 1], msg[MAX_ID + 1], del[MAX_ID + 1];
    CHECK(parse_ack_ref("room1:m1", room, msg, del) == 0 && strcmp(del, "m1") == 0, "ROOM:MSG_ID, the delivery its id");
    CHECK(parse_ack_ref("room1:m1:notice:3", room, msg, del) == 0 && strcmp(del, "notice:3") == 0, "a notice's delivery");
    CHECK(parse_ack_ref("room1", room, msg, del) < 0 && parse_ack_ref(":m1", room, msg, del) < 0 && parse_ack_ref("r:", room, msg, del) < 0,
          "malformed references refused");
}

static int head_is(const char *h, size_t cap, int want, int status, long long length) {
    struct head hd;
    unsigned char *c = dup_exact(h, strlen(h));
    int r = head_parse(c, strlen(h), cap, &hd);
    free(c);
    if (r != want) return 0;
    return want != HEAD_OK || (hd.status == status && hd.length == length);
}

static void check_head(void) {
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}", 100, HEAD_OK, 200, 2), "a plain answer");
    CHECK(head_is("HTTP/1.0 403 Forbidden\r\n\r\n", 100, HEAD_OK, 403, -1), "HTTP/1.0, no length: read to the close");
    CHECK(head_is("HTTP/1.1 204\r\n\r\n", 100, HEAD_OK, 204, -1), "no reason phrase");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\n", 100, HEAD_BAD, 0, 0), "two Content-Lengths refused");
    CHECK(head_is("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", 100, HEAD_CHUNKED, 0, 0), "chunked refused");
    CHECK(head_is("HTTP/1.1 200 OK\r\ntransfer-encoding: identity\r\n\r\n", 100, HEAD_CHUNKED, 0, 0), "any Transfer-Encoding refused");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 101\r\n\r\n", 100, HEAD_TOO_BIG, 0, 0), "a length past the cap");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: +5\r\n\r\n", 100, HEAD_BAD, 0, 0), "a signed length");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 5 5\r\n\r\n", 100, HEAD_BAD, 0, 0), "two numbers");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\n", 100, HEAD_BAD, 0, 0), "an overflowing length");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n", 100, HEAD_BAD, 0, 0), "an empty length");
    CHECK(head_is("HTTP/2 200\r\n\r\n", 100, HEAD_BAD, 0, 0) && head_is("HTTP/1.1 20 OK\r\n\r\n", 100, HEAD_BAD, 0, 0) &&
              head_is("http/1.1 200 OK\r\n\r\n", 100, HEAD_BAD, 0, 0) && head_is("HTTP/1.1 2000 OK\r\n\r\n", 100, HEAD_BAD, 0, 0),
          "status lines that are not HTTP/1.x DDD");
    CHECK(head_is("HTTP/1.1 200 OK\r\nX: a\r\n folded\r\n\r\n", 100, HEAD_BAD, 0, 0), "a folded line refused");
    CHECK(head_is("HTTP/1.1 200 OK\r\nNo colon\r\n\r\n", 100, HEAD_BAD, 0, 0) && head_is("HTTP/1.1 200 OK\r\n: x\r\n\r\n", 100, HEAD_BAD, 0, 0),
          "a line that is not a header");
    CHECK(head_is("HTTP/1.1 200 OK\r\nX: a\x01" "b\r\n\r\n", 100, HEAD_BAD, 0, 0), "a control byte in a value");
    CHECK(head_is("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n", 100, HEAD_MORE, 0, 0), "a head not finished yet");
    CHECK(head_is("HTTP/1.1 301 Moved\r\nLocation: http://elsewhere.test/\r\n\r\n", 100, HEAD_OK, 301, -1), "a redirect is only a status");
    /* A head past 64 KiB, and a header line past 8 KiB. */
    size_t big = MAX_HEAD + 10;
    char *h = malloc(big + 1);
    memcpy(h, "HTTP/1.1 200 OK\r\nX: ", 20);
    memset(h + 20, 'a', big - 20);
    h[big] = 0;
    CHECK(head_is(h, 100, HEAD_TOO_BIG, 0, 0), "a head over 64 KiB");
    size_t ll = 20 + MAX_HEADER_LINE + 10;
    memcpy(h + ll, "\r\n\r\n", 5);
    CHECK(head_is(h, 100, HEAD_BAD, 0, 0), "a header line over 8 KiB");
    free(h);
    struct head hd;
    const char *t = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\x7f; x\r\n\r\n";
    CHECK(head_parse((const unsigned char *)t, strlen(t), 100, &hd) == HEAD_BAD, "DEL in a value refused");
    t = "HTTP/1.1 200 OK\r\nContent-Type:   image/png  \r\n\r\n";
    CHECK(head_parse((const unsigned char *)t, strlen(t), 100, &hd) == HEAD_OK && strcmp(hd.type, "image/png") == 0, "the type, trimmed");
}

static void check_secrets(void) {
    memcpy(g_token, "dzc_SECRET-TOKEN-0123456789", 27);
    g_token_len = 27;
    memcpy(g_proxy_secret, "proxy-pass-1234", 15);
    g_proxy_secret_len = 15;
    char t[] = "x dzc_SECRET-TOKEN-0123456789 y proxy-pass-1234 z";
    scrub(t, strlen(t));
    CHECK(strstr(t, "SECRET") == NULL && strstr(t, "proxy-pass") == NULL, "scrubbed: %s", t);
    char r[MAX_REASON + 1];
    reason_text((const unsigned char *)"bad dzc_SECRET-TOKEN-0123456789\n", 32, r);
    CHECK(strstr(r, "SECRET") == NULL && strchr(r, '\n') == NULL, "a server's reason scrubbed and on one line: %s", r);
    wipe_secrets();
    int zero = 1;
    for (size_t i = 0; i < sizeof g_token; i++)
        if (g_token[i]) zero = 0;
    CHECK(zero && g_token_len == 0, "the token zeroed");
    CHECK(token_usable("0123456789abcdef", 16) && !token_usable("0123456789abcde", 15) && !token_usable("0123456789 abcdef", 17) &&
              !token_usable("0123456789abcd\xc3\xa9", 16),
          "a token: 16 printable ASCII, no spaces");
}

/* A small seeded generator (xorshift64*). */
static uint64_t rng = 88172645463325252ULL;
static uint64_t rnd(void) {
    rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
    return rng * 2685821657736338717ULL;
}

static void fuzz_escaper(long iterations) {
    static const unsigned char pool[] = {'a', '"', '\\', '\n', 0, 0x1f, 0x7f, 0x80, 0xbf, 0xc0, 0xc2, 0xc3, 0xdf, 0xe0, 0xe2,
                                         0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xff, 0x82, 0x9f, 0xa0, 0x90, 0x8f, '/', 'u'};
    long ok = 0, refused = 0, bad = 0;
    for (long it = 0; it < iterations; it++) {
        size_t n = (size_t)(rnd() % 48);
        unsigned char s[48];
        int only_valid = (int)(rnd() % 2); /* half the strings are valid UTF-8 by construction */
        for (size_t i = 0; i < n; i++) {
            uint64_t r = rnd();
            if (only_valid && r % 4 != 0) { s[i] = pool[(r >> 8) % 7]; continue; }
            if (r % 4 == 0) {
                /* A valid code point, encoded. */
                struct buf one = buf_new(8);
                unsigned long cp = (unsigned long)(rnd() % 0x110000);
                if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0x41;
                put_utf8(&one, cp);
                for (size_t k = 0; k < one.len && i < n; k++) s[i++] = one.p[k];
                buf_free(&one);
                i--;
            } else s[i] = pool[(r >> 8) % sizeof pool];
        }
        struct buf out = buf_new(1 << 16);
        int r = esc(s, n, &out);
        int valid = ref_utf8_valid(s, n);
        if (r == ESC_OK) {
            ok++;
            size_t a, b;
            struct buf back = buf_new(1 << 16);
            if (!valid || scan_document(out.p, out.len, &a, &b) != 0 || a != 0 || b != out.len ||
                json_decode_string(&back, out.p, a, b) != 0 || back.len != n || (n && memcmp(back.p, s, n) != 0))
                bad++;
            for (size_t k = 1; k + 1 < out.len; k++)
                if (out.p[k] < 0x20 || out.p[k] == 0x7f) bad++;
            buf_free(&back);
        } else {
            refused++;
            if (r != ESC_INVALID || valid) bad++;
        }
        buf_free(&out);
    }
    CHECK(bad == 0, "escaper fuzz: %ld wrong of %ld (%ld escaped, %ld refused)", bad, iterations, ok, refused);
    CHECK(ok > iterations / 10 && refused > iterations / 10, "escaper fuzz covers both sides (%ld, %ld)", ok, refused);
}

static void fuzz_scanner(long iterations) {
    const char *seeds[] = {
        "{\"messages\":[{\"room\":\"room1\",\"msg_id\":\"m1\",\"delivery\":\"m1\",\"message\":{\"content\":\"hi \\\"x\\\" \\u00e9\"}}],\"protocol_version\":\"a\"}",
        "{\"state\":\"queued\",\"msg_id\":\"6f\",\"detail\":\"\\ud83d\\ude00\"}",
        "{\"error\":\"no\",\"detail\":[1,2,{\"a\":null}]}",
        "[[[[[[[[[[[[[[[[[[[[\"deep\"]]]]]]]]]]]]]]]]]]]]",
    };
    static const unsigned char pool[] = {'{', '}', '[', ']', '"', '\\', ':', ',', ' ', 'u', 'd', '8', '0', 'a', 'n', 0, 0x1f, 0xff, 't'};
    long scanned = 0;
    for (long it = 0; it < iterations; it++) {
        const char *seed = seeds[rnd() % 4];
        size_t n = strlen(seed);
        unsigned char s[512];
        memcpy(s, seed, n);
        int muts = 1 + (int)(rnd() % 4);
        for (int m = 0; m < muts; m++) {
            uint64_t r = rnd();
            size_t at = n ? (size_t)(r % n) : 0;
            switch ((r >> 20) % 4) {
            case 0: if (n) s[at] = pool[(r >> 32) % sizeof pool]; break;
            case 1: if (n < sizeof s - 1) { memmove(s + at + 1, s + at, n - at); s[at] = pool[(r >> 32) % sizeof pool]; n++; } break;
            case 2: if (n) { memmove(s + at, s + at + 1, n - at - 1); n--; } break;
            default: n = at; break;
            }
        }
        unsigned char *c = dup_exact(s, n);
        size_t a, b, count;
        if (scan_document(c, n, &a, &b) == 0) {
            scanned++;
            struct buf o = buf_new(1 << 16);
            if (json_compact(&o, c, a, b) == 0) {
                size_t a2, b2;
                unsigned char *c2 = dup_exact(o.p, o.len);
                CHECK(scan_document(c2, o.len, &a2, &b2) == 0, "a compacted document scans again");
                free(c2);
            }
            buf_free(&o);
            if (c[a] == '{') {
                struct buf v = buf_new(4096);
                (void)obj_string(c, a, b, "detail", &v);
                buf_free(&v);
                char id[MAX_ID + 1];
                (void)ack_id(c, a, b, "msg_id", id);
            }
        }
        struct collect col;
        memset(&col, 0, sizeof col);
        (void)each_message(c, n, collect_id, &col, &count);
        struct head hd;
        (void)head_parse(c, n, 1000, &hd);
        free(c);
    }
    CHECK(scanned > 0, "scanner fuzz: some mutations still scan (%ld of %ld)", scanned, iterations);
}

/* The address when CHAT_URL is not set: on a Mac with no proxy, this Mac's loopback (a session run without a fence);
 * with a proxy, or on Linux, host.dozable.internal. Only the choice is checked: nothing is connected to. */
static void check_default_url(void) {
    unsetenv("http_proxy");
    unsetenv("HTTP_PROXY");
#if defined(__APPLE__)
    CHECK(strcmp(default_url(), "http://127.0.0.1:8790") == 0, "a Mac with no proxy: 127.0.0.1:8790 (%s)", default_url());
#else
    CHECK(strcmp(default_url(), DEFAULT_URL) == 0, "Linux: host.dozable.internal (%s)", default_url());
#endif
    setenv("HTTP_PROXY", "http://127.0.0.1:9", 1);
    CHECK(strcmp(default_url(), DEFAULT_URL) == 0, "a proxy set: host.dozable.internal (%s)", default_url());
    setenv("HTTP_PROXY", "", 1);
    setenv("http_proxy", "http://127.0.0.1:9", 1);
    CHECK(strcmp(default_url(), DEFAULT_URL) == 0, "http_proxy set: host.dozable.internal (%s)", default_url());
    unsetenv("http_proxy");
    unsetenv("HTTP_PROXY");
}

/* send's options go before or after the text; several words are positional (cmd_send joins them). */
static void check_send_options(void) {
    struct opts o;
    char *a1[] = {"dozchat", "send", "room1", "--re", "abc123", "hello", NULL};
    CHECK(parse_opts(6, a1, 2, " --re --to --dm ", &o) == EXIT_DONE && o.npos == 2 && o.re && strcmp(o.re, "abc123") == 0 &&
              strcmp(o.pos[1], "hello") == 0, "send ROOM --re ID TEXT");
    char *a2[] = {"dozchat", "send", "room1", "hello", "--re", "abc123", NULL};
    CHECK(parse_opts(6, a2, 2, " --re --to --dm ", &o) == EXIT_DONE && o.npos == 2 && o.re && strcmp(o.re, "abc123") == 0 &&
              strcmp(o.pos[1], "hello") == 0, "send ROOM TEXT --re ID");
    char *a3[] = {"dozchat", "send", "room1", "hello", "there", "--re=abc123", "again", NULL};
    CHECK(parse_opts(7, a3, 2, " --re --to --dm ", &o) == EXIT_DONE && o.npos == 4 && o.re && strcmp(o.re, "abc123") == 0,
          "send ROOM WORDS… --re=ID WORDS…");
}

static int escape_mode(const char *file) {
    FILE *f = fopen(file, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", file); return 2; }
    static char line[1 << 16];
    while (fgets(line, sizeof line, f)) {
        size_t l = strlen(line);
        while (l && (line[l - 1] == '\n' || line[l - 1] == '\r')) line[--l] = 0;
        size_t n = l / 2;
        unsigned char *b = malloc(n ? n : 1);
        for (size_t i = 0; i < n; i++) b[i] = (unsigned char)(hex_val((unsigned char)line[2 * i]) * 16 + hex_val((unsigned char)line[2 * i + 1]));
        struct buf o = buf_new(1 << 20);
        if (json_str(&o, b, n) == ESC_OK) { fwrite(o.p, 1, o.len, stdout); fputc('\n', stdout); }
        else fputs("!\n", stdout);
        buf_free(&o);
        free(b);
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    const char *vectors = "clean-name.tsv";
    long iterations = 25000;
    if (argc == 3 && strcmp(argv[1], "escape") == 0) return escape_mode(argv[2]);
    for (int i = 1; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "--vectors") == 0) vectors = argv[i + 1];
        else if (strcmp(argv[i], "--iterations") == 0) iterations = atol(argv[i + 1]);
        else if (strcmp(argv[i], "--seed") == 0) rng = (uint64_t)strtoull(argv[i + 1], NULL, 10) | 1;
    }
    check_escaper();
    check_scanner();
    check_base64();
    check_clean_name(vectors);
    check_urls();
    check_head();
    check_secrets();
    check_default_url();
    check_send_options();
    fuzz_escaper(iterations);
    fuzz_scanner(iterations);
    if (failures) {
        fprintf(stderr, "x dozchat-check: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("ok dozchat-check: %d checks, %ld fuzz iterations each for the escaper and the scanner\n", checks, iterations);
    return 0;
}
