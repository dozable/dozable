/*
 * grid-check.c — deckhold's GRID (648): the screen as cells a dashboard thumbnail paints. Checked against the
 * holder's own screen: every row's text equals what `deckhold dump` prints for it (fixed cases + a seeded fuzz of
 * styled text, cursor moves, erases, wide characters and resizes), the colours and flags of chosen cells, the
 * cursor, the gen (it moves with output and a resize, and an unchanged one is answered "unchanged"), the limits
 * (a row's text, a screen past 1000×500), and the frames on the wire (WATCH announces it; INFO lists it; a GRID
 * never makes its client a viewer). deckhold's own code (`#include "../deckhold.c"`), built for the Mac by run.sh.
 *
 * Exit 0 = every check passed. Usage: grid-check [fuzz-iterations] [seed]
 */
#define main deckhold_main
#include "../deckhold.c"
#undef main

static int failures, checks;

static void check(bool ok, const char *what) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
}

/* ── a decoder of the GRID answer (the host's Swift decoder is the other one) ── */

struct run { uint16_t col, cells; uint8_t flags; bool has_fg, has_bg; GhosttyColorRgb fg, bg; char *text; uint16_t len; };
struct grid {
    uint8_t version, changed;
    uint32_t gen;
    uint16_t cols, rows, cx, cy;
    bool cursor;
    GhosttyColorRgb fg, bg;
    int *nruns;
    struct run **runs;
};

static void grid_free(struct grid *g) {
    if (g->runs) {
        for (int y = 0; y < g->rows; y++) {
            for (int i = 0; i < g->nruns[y]; i++) free(g->runs[y][i].text);
            free(g->runs[y]);
        }
    }
    free(g->runs); free(g->nruns);
    memset(g, 0, sizeof *g);
}

/* Parse one 'G' payload. False on any malformation (lengths that run past the end, trailing bytes). */
static bool grid_parse(const uint8_t *p, size_t n, struct grid *g) {
    memset(g, 0, sizeof *g);
    size_t at = 0;
#define NEED(k) do { if (at + (k) > n) return false; } while (0)
    NEED(6);
    g->version = p[0]; g->gen = be32(p + 1); g->changed = p[5]; at = 6;
    if (g->changed != GRID_FOLLOWS) return at == n;
    NEED(15);
    g->cols = be16(p + at); g->rows = be16(p + at + 2); g->cursor = p[at + 4]; g->cx = be16(p + at + 5); g->cy = be16(p + at + 7);
    g->fg = (GhosttyColorRgb){ p[at + 9], p[at + 10], p[at + 11] };
    g->bg = (GhosttyColorRgb){ p[at + 12], p[at + 13], p[at + 14] };
    at += 15;
    g->nruns = calloc(g->rows, sizeof *g->nruns);
    g->runs = calloc(g->rows, sizeof *g->runs);
    for (int y = 0; y < g->rows; y++) {
        NEED(2);
        int k = be16(p + at); at += 2;
        g->nruns[y] = k;
        g->runs[y] = calloc(k ? k : 1, sizeof **g->runs);
        for (int i = 0; i < k; i++) {
            struct run *r = &g->runs[y][i];
            NEED(15);
            r->col = be16(p + at); r->cells = be16(p + at + 2); r->flags = p[at + 4];
            r->has_fg = p[at + 5]; r->fg = (GhosttyColorRgb){ p[at + 6], p[at + 7], p[at + 8] };
            r->has_bg = p[at + 9]; r->bg = (GhosttyColorRgb){ p[at + 10], p[at + 11], p[at + 12] };
            r->len = be16(p + at + 13); at += 15;
            NEED(r->len);
            r->text = malloc(r->len + 1u);
            memcpy(r->text, p + at, r->len);
            r->text[r->len] = 0;
            at += r->len;
        }
    }
#undef NEED
    return at == n;
}

/* Ask: one GRID frame through client_frames (the wire path), the answer parsed. */
static bool ask(uint32_t gen, struct grid *g) {
    struct client c = { .fd = -1 };
    uint8_t q[4] = { (uint8_t)(gen >> 24), (uint8_t)(gen >> 16), (uint8_t)(gen >> 8), (uint8_t)gen };
    frame(&c.in, F_GRID, q, 4);
    bool ok = client_frames(&c) && !c.hello && c.out.len >= 5 && c.out.p[0] == F_GRID && c.out.len == 5 + be32(c.out.p + 1)
              && grid_parse(c.out.p + 5, c.out.len - 5, g);
    buf_free(&c.in); buf_free(&c.out);
    return ok;
}

/* The program writes `s`: through the real output path (pump_master reading the pty master — here a pipe). */
static int pipe_w = -1;
static void out(const char *s) {
    size_t n = strlen(s), at = 0;
    while (at < n) {
        ssize_t w = write(pipe_w, s + at, n - at);
        if (w > 0) at += (size_t)w;
        pump_master();
    }
    pump_master();
}

static void fresh_screen(uint16_t cols, uint16_t rows) {
    if (S.term) ghostty_terminal_free(S.term);
    GhosttyTerminalOptions to = { .cols = cols, .rows = rows, .max_scrollback = 1 << 20 };
    ghostty_terminal_new(NULL, &S.term, to);
    S.cols = cols; S.rows = rows;
    S.gen = 1;
    buf_free(&S.master_out);
}

/* A row of the grid as text: each run's text at its column (columns, not characters: a wide character's tail
 * adds a column, no text), trailing spaces trimmed. */
static char *row_text(const struct grid *g, int y) {
    struct buf b = {0};
    int col = 0;
    for (int i = 0; i < g->nruns[y]; i++) {
        const struct run *r = &g->runs[y][i];
        while (col < r->col) { buf_add(&b, " ", 1); col++; }
        buf_add(&b, r->text, r->len);
        col += r->cells;
    }
    while (b.len && b.p[b.len - 1] == ' ') b.len--;
    buf_add(&b, "", 1);
    char *s = strdup((char *)b.p);
    buf_free(&b);
    return s;
}

/* The holder's own screen, row by row (`deckhold dump`'s text without its last line), trailing spaces trimmed. */
static char **dump_rows(int rows) {
    struct buf b = {0};
    dump_screen(&b);
    char *text = strndup((char *)b.p + 5, be32(b.p + 1));
    buf_free(&b);
    char *tail = strstr(text, "\ncursor=");
    if (tail) *tail = 0; else if (!strncmp(text, "cursor=", 7)) *text = 0;
    char **out = calloc(rows, sizeof *out);
    char *line = text;
    for (int y = 0; y < rows; y++) {
        char *nl = line ? strchr(line, '\n') : NULL;
        if (nl) *nl = 0;
        size_t n = line ? strlen(line) : 0;
        while (n && line[n - 1] == ' ') n--;
        out[y] = line ? strndup(line, n) : strdup("");
        line = nl ? nl + 1 : NULL;
    }
    free(text);
    return out;
}

/* Every row of the grid has the text the holder's screen has. */
static bool same_text(const struct grid *g, const char *what) {
    char **want = dump_rows(g->rows);
    bool ok = true;
    for (int y = 0; y < g->rows; y++) {
        char *got = row_text(g, y);
        if (strcmp(got, want[y]) != 0) {
            if (ok) printf("     %s row %d: grid [%s] screen [%s]\n", what, y, got, want[y]);
            ok = false;
        }
        free(got);
        free(want[y]);
    }
    free(want);
    return ok;
}

/* The run that covers column x of row y (NULL: none — a default blank). */
static const struct run *at_cell(const struct grid *g, int y, int x) {
    for (int i = 0; i < g->nruns[y]; i++) {
        const struct run *r = &g->runs[y][i];
        if (x >= r->col && x < r->col + r->cells) return r;
    }
    return NULL;
}

static bool rgb(GhosttyColorRgb c, int r, int g, int b) { return c.r == r && c.g == g && c.b == b; }

static GhosttyColorRgb palette(int i) {
    GhosttyColorRgb p[256];
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, p);
    return p[i];
}

int main(int argc, char **argv) {
    int iterations = argc > 1 ? atoi(argv[1]) : 2000;
    unsigned seed = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 648;
    int fds[2];
    if (pipe(fds) != 0) { printf("FAIL pipe\n"); return 2; }
    S.master = fds[0];
    pipe_w = fds[1];
    set_nonblock(S.master);
    S.name = "main";
    snprintf(S.cmdline, sizeof S.cmdline, "agent --go");

    /* 1. Styled text: colours, flags, the cursor, the text of every row. */
    fresh_screen(40, 6);
    out("hello \x1b[1;31mred\x1b[0m \x1b[42mgreen bg\x1b[0m\r\n"
        "rgb \x1b[38;2;10;20;30mdeep\x1b[0m \x1b[3;4mit\x1b[0m \x1b[2mfaint\x1b[0m\r\n"
        "\x1b[7mINV\x1b[0m wide:\xe6\xbc\xa2!\r\n"
        "\x1b[44m    \x1b[0m<-blue spaces");
    struct grid g;
    check(ask(0, &g), "a GRID asked with gen 0 is answered and parses");
    check(g.version == 1 && g.changed == GRID_FOLLOWS && g.cols == 40 && g.rows == 6, "version 1, a grid of 40×6");
    check(same_text(&g, "styled"), "every row's text is the screen's");
    const struct run *red = at_cell(&g, 0, 6);
    check(red && red->col == 6 && red->cells == 3 && !strcmp(red->text, "red"), "\"red\" is one run at column 6");
    check(red && red->has_fg && rgb(red->fg, palette(1).r, palette(1).g, palette(1).b) && (red->flags & GF_BOLD) && !red->has_bg,
          "…bold, in palette red, on the default background");
    const struct run *green = at_cell(&g, 0, 11);
    check(green && green->has_bg && rgb(green->bg, palette(2).r, palette(2).g, palette(2).b) && !green->has_fg, "green background, default text");
    const struct run *deep = at_cell(&g, 1, 4);
    check(deep && deep->has_fg && rgb(deep->fg, 10, 20, 30), "a 24-bit colour is resolved as it is");
    const struct run *it = at_cell(&g, 1, 9);
    check(it && (it->flags & GF_ITALIC) && (it->flags & GF_UNDERLINE) && !(it->flags & GF_BOLD), "italic + underline");
    const struct run *faint = at_cell(&g, 1, 12);
    check(faint && (faint->flags & GF_FAINT), "faint");
    const struct run *inv = at_cell(&g, 2, 0);
    check(inv && (inv->flags & GF_INVERSE) && inv->has_fg && inv->has_bg && rgb(inv->fg, g.bg.r, g.bg.g, g.bg.b) && rgb(inv->bg, g.fg.r, g.fg.g, g.fg.b),
          "inverse is applied: the default colours swapped");
    const struct run *wide = at_cell(&g, 2, 9);
    check(wide && strstr(wide->text, "\xe6\xbc\xa2!") && at_cell(&g, 2, 10) == wide && at_cell(&g, 2, 11) == wide,
          "a wide character: one grapheme, two columns, then the next");
    check(wide && wide->col == 4 && !strncmp(wide->text, "wide:", 5), "a default run starts at its first visible cell (the gap is dropped)");
    { const struct run *last = g.nruns[2] ? &g.runs[2][g.nruns[2] - 1] : NULL;
      check(last && last->col + last->cells == 12, "…the run's cells count the tail column; the blank tail of a row is dropped"); }
    const struct run *blue = at_cell(&g, 3, 0);
    check(blue && blue->has_bg && blue->cells == 4 && !strcmp(blue->text, "    "), "spaces with a background are a run");
    check(g.nruns[4] == 0 && g.nruns[5] == 0, "a blank default row has no run");
    { bool none = true; for (int y = 0; y < g.rows; y++) for (int i = 0; i < g.nruns[y]; i++) {
        const struct run *r = &g.runs[y][i];
        bool blank = true; for (int k = 0; k < r->len; k++) blank &= r->text[k] == ' ';
        if (blank && !r->has_fg && !r->has_bg && !(r->flags & (GF_UNDERLINE | GF_INVERSE))) none = false; }
      check(none, "no run is default-coloured spaces"); }
    uint16_t cx = 0, cy = 0;
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
    ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
    check(g.cursor && g.cx == cx && g.cy == cy && cy == 3, "the cursor is where the holder has it");
    uint32_t gen = g.gen;
    grid_free(&g);

    /* 2. The gen: unchanged answers unchanged; output, a resize, a clear move it. */
    check(ask(gen, &g) && g.changed == GRID_UNCHANGED && g.gen == gen, "the same gen: \"unchanged\", nothing follows");
    grid_free(&g);
    out("x");
    check(ask(gen, &g) && g.changed == GRID_FOLLOWS && g.gen != gen, "output moves the gen: a grid");
    gen = g.gen; grid_free(&g);
    resize_to(30, 6);
    check(ask(gen, &g) && g.changed == GRID_FOLLOWS && g.cols == 30 && g.gen != gen, "a resize moves the gen: the new size");
    gen = g.gen; grid_free(&g);
    out("\x1b[2J\x1b[H");
    check(ask(gen, &g) && g.changed == GRID_FOLLOWS && g.nruns[0] == 0 && g.nruns[3] == 0, "a clear: an empty grid");
    gen = g.gen; grid_free(&g);
    out("\x1b[?25l");
    check(ask(gen, &g) && !g.cursor, "a hidden cursor: none");
    grid_free(&g);
    { struct client c = { .fd = -1 }; frame(&c.in, F_GRID, NULL, 0);
      check(client_frames(&c) && c.out.p[0] == F_GRID && grid_parse(c.out.p + 5, c.out.len - 5, &g) && g.changed == GRID_FOLLOWS,
            "a GRID with no gen (an empty payload) is gen 0");
      grid_free(&g); buf_free(&c.in); buf_free(&c.out); }

    /* 3. Limits: a row's text stops at 4096 bytes; a screen past 1000×500 has no grid. */
    fresh_screen(1000, 3);
    { struct buf b = {0};
      for (int i = 0; i < 1000; i++) {
          if (i % 50 == 0) { char sgr[16]; snprintf(sgr, sizeof sgr, "\x1b[3%dm", 1 + (i / 50) % 6); buf_str(&b, sgr); }
          buf_str(&b, "e\xcc\x81\xcc\x82");                     /* 5 bytes a column */
      }
      buf_add(&b, "", 1); out((char *)b.p); buf_free(&b); }
    check(ask(0, &g), "a 1000-column row of 5-byte graphemes");
    { size_t text = 0; for (int i = 0; i < g.nruns[0]; i++) text += g.runs[0][i].len;
      check(text > 0 && text <= GRID_ROW_TEXT && g.nruns[0] < 20, "its text stops at 4096 bytes (whole runs)"); }
    grid_free(&g);
    fresh_screen(80, 501);
    out("tall");
    check(ask(0, &g) && g.changed == GRID_NONE, "501 rows: no grid (none)");
    grid_free(&g);
    fresh_screen(1000, 500);
    out("big");
    check(ask(0, &g) && g.changed == GRID_FOLLOWS && g.rows == 500, "1000×500: a grid");
    grid_free(&g);

    /* 4. The frames: WATCH announces GRID first; INFO lists it before the status; GRID is not a viewer. */
    fresh_screen(80, 24);
    { struct client c = { .fd = -1 };
      frame(&c.in, F_WATCH, NULL, 0);
      frame(&c.in, F_GRID, (uint8_t[4]){0, 0, 0, 0}, 4);
      check(client_frames(&c), "WATCH then GRID on one client");
      uint32_t n1 = be32(c.out.p + 1);
      check(c.out.p[0] == F_STATUS && n1 == 6 && !memcmp(c.out.p + 5, "grid=1", 6), "the WATCH answer is `grid=1` (no record)");
      check(c.out.p[5 + n1] == F_GRID && !c.hello && attached_count() == 0, "then the GRID answer; the client is no viewer");
      buf_free(&c.in); buf_free(&c.out); }
    out("\x1b]7501;state=working:app=a\x1b\\");
    { struct client c = { .fd = -1 };
      frame(&c.in, F_WATCH, NULL, 0);
      check(client_frames(&c), "WATCH with a record");
      char *t = strndup((char *)c.out.p + 5, be32(c.out.p + 1));
      const char *want = "grid=1\tstatus=state=working:app=a\tstatus_age=";
      check(!strncmp(t, want, strlen(want)), "`grid=1` then the status fields");
      free(t); buf_free(&c.in); buf_free(&c.out); }
    { struct buf b = {0}; info_line(&b); buf_add(&b, "", 1);
      const char *line = (char *)b.p + 5;
      check(strstr(line, "\tbytes=") && strstr(line, "\tgrid=1\tstatus=state=working:app=a\tstatus_age=") && strstr(line, "\tagent --go"),
            "INFO: `grid=1` before the status and the command");
      buf_free(&b); }

    /* 5. Fuzz: random styled output, cursor moves, erases, wide characters, scrolling and resizes — every grid's
     * text equals the screen's, every grid parses, and nothing is asked twice for the same gen. */
    static const char *const parts[] = {
        "abc", "hello world", " ", "  x  ", "\r\n", "\n", "\r", "\t", "\x1b[1m", "\x1b[0m", "\x1b[31m", "\x1b[42m", "\x1b[7m",
        "\x1b[38;5;200m", "\x1b[48;2;1;2;3m", "\x1b[4m", "\x1b[3m", "\x1b[2m", "\x1b[H", "\x1b[5;3H", "\x1b[K", "\x1b[2K",
        "\x1b[J", "\x1b[2J", "\x1b[3A", "\x1b[10C", "\x1b[?1049h", "\x1b[?1049l", "\xe6\xbc\xa2", "\xf0\x9f\x98\x80", "e\xcc\x81",
        "\xe2\x9c\x93", "\x1b[L", "\x1b[M", "\x1b[@", "\x1b[P", "\x1b[S", "\x1b[T", ("\x1b" "c"), "\x1b[?25l", "\x1b[?25h",
    };
    const int nparts = sizeof parts / sizeof parts[0];
    srand(seed);
    int bad = 0, bad_parse = 0, bad_cursor = 0;
    for (int it = 0; it < iterations; it++) {
        if (it % 50 == 0) fresh_screen((uint16_t)(10 + rand() % 70), (uint16_t)(3 + rand() % 20));
        int k = 1 + rand() % 30;
        struct buf b = {0};
        for (int j = 0; j < k; j++) buf_str(&b, parts[rand() % nparts]);
        buf_add(&b, "", 1);
        out((char *)b.p);
        buf_free(&b);
        if (rand() % 10 == 0) resize_to((uint16_t)(10 + rand() % 70), (uint16_t)(3 + rand() % 20));
        if (!ask(0, &g) || g.changed != GRID_FOLLOWS) { bad_parse++; grid_free(&g); continue; }
        char what[32];
        snprintf(what, sizeof what, "fuzz %d", it);
        if (!same_text(&g, what)) bad++;
        uint16_t x = 0, y = 0;
        ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y);
        ghostty_terminal_get(S.term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);
        if (g.cursor && (g.cy != y || g.cx != x)) bad_cursor++;
        grid_free(&g);
    }
    char label[128];
    snprintf(label, sizeof label, "fuzz: %d screens (seed %u), every grid parses", iterations, seed);
    check(bad_parse == 0, label);
    snprintf(label, sizeof label, "fuzz: every row's text is the screen's (%d differ)", bad);
    check(bad == 0, label);
    snprintf(label, sizeof label, "fuzz: the cursor is the holder's (%d differ)", bad_cursor);
    check(bad_cursor == 0, label);

    printf("%s: %d checks, %d failed\n", failures ? "grid-check FAILED" : "grid-check ok", checks, failures);
    return failures ? 1 : 0;
}
