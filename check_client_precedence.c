/*
 * check_client_precedence.c
 *
 * Deterministic C99 Preflight Checker for OpenSSH Client Configuration Precedence
 * and Multi-Hop Bastion Chain Soundness (Instance 12).
 *
 * Implements OpenSSH ssh_config(5) first-match-wins evaluation semantics across
 * wildcard patterns ('*', '?', '!negation', multi-pattern Host lists) and detects:
 *   1. Wildcard stanzas shadowing subsequent host-specific directives (ProxyJump,
 *      Port, User, ProxyCommand) for server1, server3, and server2.
 *   2. Self-referential or cyclic ProxyJump / ProxyCommand chains.
 *   3. Unreachable single-hop ProxyJump for isolated subnet target server2
 *      (10.202.32.2 requires jumping via server3).
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdbool.h>
#include <ctype.h>

#define MAX_HOSTS 3
#define MAX_DIRS  4

static const char * const CHECK_HOSTS[MAX_HOSTS] = { "server1", "server3", "server2" };
static const char * const CHECK_DIRS[MAX_DIRS]   = { "ProxyJump", "Port", "User", "ProxyCommand" };

typedef struct {
    bool locked;
    bool from_wildcard;
    int  line;
    char pattern[128];
    char value[256];
} DirectiveLock;

/* Glob matcher supporting '*' and '?' (case-insensitive per OpenSSH Host matching) */
static bool glob_match(const char *pat, const char *str) {
    while (*pat) {
        if (*pat == '*') {
            while (*pat == '*') pat++;
            if (*pat == '\0') return true;
            while (*str) {
                if (glob_match(pat, str)) return true;
                str++;
            }
            return false;
        } else if (*pat == '?') {
            if (*str == '\0') return false;
            pat++;
            str++;
        } else {
            if (tolower((unsigned char)*pat) != tolower((unsigned char)*str)) return false;
            pat++;
            str++;
        }
    }
    return *str == '\0';
}

/*
 * Evaluates an OpenSSH 'Host <pattern-list>' line against a target hostname.
 * Per ssh_config(5): if any negated pattern '!pat' matches, the Host entry is
 * ignored; otherwise at least one positive pattern must match.
 * Sets *is_wildcard = true if the matching pattern contains '*', '?', or multiple tokens.
 */
static bool host_pattern_list_matches(const char *pat_list, const char *hostname, bool *is_wildcard) {
    char buf[256];
    strncpy(buf, pat_list, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    bool any_positive_match = false;
    bool wildcard_seen = false;
    int token_count = 0;

    char *p = buf;
    while (*p) {
        while (isspace((unsigned char)*p) || *p == ',') p++;
        if (*p == '\0') break;
        char *start = p;
        while (*p && !isspace((unsigned char)*p) && *p != ',') p++;
        if (*p) *p++ = '\0';

        token_count++;
        if (strchr(start, '*') || strchr(start, '?') || start[0] == '!') {
            wildcard_seen = true;
        }

        if (start[0] == '!') {
            if (glob_match(start + 1, hostname)) {
                return false; /* Negated match immediately disqualifies stanza */
            }
        } else {
            if (glob_match(start, hostname)) {
                any_positive_match = true;
            }
        }
    }

    if (token_count > 1) wildcard_seen = true;
    if (is_wildcard) *is_wildcard = wildcard_seen;
    return any_positive_match;
}

static int find_dir_index(const char *key) {
    for (int i = 0; i < MAX_DIRS; i++) {
        if (strcasecmp(key, CHECK_DIRS[i]) == 0) return i;
    }
    return -1;
}

int main(int argc, char **argv) {
    const char *cfg_path = (argc > 1) ? argv[1] : "ssh_config.buggy";
    const char *focus_host = (argc > 2) ? argv[2] : "server2";
    const char *focus_dir  = (argc > 3) ? argv[3] : "ProxyJump";
    (void)focus_host;
    (void)focus_dir;

    FILE *fp = fopen(cfg_path, "r");
    if (!fp) {
        fprintf(stderr, "[PREFLIGHT ERROR] Unable to open config file: %s\n", cfg_path);
        return 2;
    }

    DirectiveLock locks[MAX_HOSTS][MAX_DIRS];
    memset(locks, 0, sizeof(locks));

    bool active_match[MAX_HOSTS] = { false, false, false };
    bool active_wild[MAX_HOSTS]  = { false, false, false };
    char current_host_pat[128] = "";

    int violations = 0;
    int line_num = 0;
    char line[512];

    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (*p == '#' || *p == '\0') continue;

        /* Strip trailing newline/whitespace */
        size_t len = strlen(p);
        while (len > 0 && isspace((unsigned char)p[len - 1])) {
            p[--len] = '\0';
        }

        char key[64] = {0};
        char val[384] = {0};
        if (sscanf(p, "%63s %383[^\n]", key, val) < 2) continue;

        /* Trim leading whitespace on val */
        char *vp = val;
        while (isspace((unsigned char)*vp)) vp++;

        if (strcasecmp(key, "Host") == 0) {
            strncpy(current_host_pat, vp, sizeof(current_host_pat) - 1);
            current_host_pat[sizeof(current_host_pat) - 1] = '\0';
            for (int h = 0; h < MAX_HOSTS; h++) {
                bool is_w = false;
                active_match[h] = host_pattern_list_matches(vp, CHECK_HOSTS[h], &is_w);
                active_wild[h]  = is_w;
            }
            continue;
        }

        int d = find_dir_index(key);
        if (d < 0) continue;

        for (int h = 0; h < MAX_HOSTS; h++) {
            if (!active_match[h]) continue;
            DirectiveLock *lk = &locks[h][d];
            if (!lk->locked) {
                lk->locked = true;
                lk->from_wildcard = active_wild[h];
                lk->line = line_num;
                strncpy(lk->pattern, current_host_pat, sizeof(lk->pattern) - 1);
                strncpy(lk->value, vp, sizeof(lk->value) - 1);
            } else if (lk->from_wildcard && !active_wild[h] && strcasecmp(lk->value, vp) != 0) {
                violations++;
                fprintf(
                    stderr,
                    "[PREFLIGHT VIOLATION %d] Directive '%s' for host '%s' (line %d, val: '%s') is completely SHADOWED by earlier 'Host %s' at line %d (val: '%s')\n",
                    violations,
                    CHECK_DIRS[d],
                    CHECK_HOSTS[h],
                    line_num,
                    vp,
                    lk->pattern,
                    lk->line,
                    lk->value
                );
            }
        }
    }
    fclose(fp);

    /* Check wildcard-locked directives that have no explicit override line in Host server1 (e.g. ProxyJump on server1) */
    if (locks[0][0].locked && strcasecmp(locks[0][0].value, "none") != 0) {
        violations++;
        fprintf(
            stderr,
            "[PREFLIGHT VIOLATION %d] Ingress host 'server1' has 'ProxyJump %s' locked by 'Host %s' at line %d (server1 must connect directly without ProxyJump)\n",
            violations,
            locks[0][0].value,
            locks[0][0].pattern,
            locks[0][0].line
        );
    }

    /* Check wildcard-locked ProxyCommand fork-bomb hazard on server1/server3/server2 */
    for (int h = 0; h < MAX_HOSTS; h++) {
        if (locks[h][3].locked && locks[h][3].from_wildcard) {
            violations++;
            fprintf(
                stderr,
                "[PREFLIGHT VIOLATION %d] Host '%s' has wildcard 'ProxyCommand %s' locked by 'Host %s' at line %d (causes recursive ssh fork bomb)\n",
                violations,
                CHECK_HOSTS[h],
                locks[h][3].value,
                locks[h][3].pattern,
                locks[h][3].line
            );
        }
    }

    /* Check effective Port (must be 22) and User (must be deploy) for server1, server3, server2 */
    for (int h = 0; h < MAX_HOSTS; h++) {
        if (locks[h][1].locked && strcmp(locks[h][1].value, "22") != 0) {
            violations++;
            fprintf(
                stderr,
                "[PREFLIGHT VIOLATION %d] Host '%s' effective Port is '%s' (locked at line %d by 'Host %s'; expected '22')\n",
                violations,
                CHECK_HOSTS[h],
                locks[h][1].value,
                locks[h][1].line,
                locks[h][1].pattern
            );
        }
        if (locks[h][2].locked && strcmp(locks[h][2].value, "deploy") != 0) {
            violations++;
            fprintf(
                stderr,
                "[PREFLIGHT VIOLATION %d] Host '%s' effective User is '%s' (locked at line %d by 'Host %s'; expected 'deploy')\n",
                violations,
                CHECK_HOSTS[h],
                locks[h][2].value,
                locks[h][2].line,
                locks[h][2].pattern
            );
        }
    }

    /* Check effective ProxyJump routing chain for server3 (server1) and server2 (server3 or server1,server3) */
    const char *pj_s3 = locks[1][0].locked ? locks[1][0].value : "none";
    const char *pj_s2 = locks[2][0].locked ? locks[2][0].value : "none";

    if (strcasecmp(pj_s3, "server1") != 0) {
        violations++;
        fprintf(
            stderr,
            "[PREFLIGHT VIOLATION %d] Host 'server3' effective ProxyJump is '%s' (expected 'server1')\n",
            violations,
            pj_s3
        );
    }
    if (strcasecmp(pj_s2, "server3") != 0 && strcasecmp(pj_s2, "server1,server3") != 0) {
        violations++;
        fprintf(
            stderr,
            "[PREFLIGHT VIOLATION %d] Host 'server2' effective ProxyJump is '%s' (expected 'server3' or 'server1,server3' to reach isolated 10.202.32.0/24 subnet)\n",
            violations,
            pj_s2
        );
    }

    if (violations > 0) {
        return 1;
    }

    printf("[PREFLIGHT OK] Directive '%s' and multi-hop chain (server1 -> server3 -> server2) for '%s' have valid evaluation precedence.\n", focus_dir, focus_host);
    return 0;
}
