/*
 * check_client_precedence.c
 * 
 * Deterministic C99 Preflight Checker for OpenSSH Client Configuration Precedence.
 * Detects whether host-specific directives (e.g. Host server2 / ProxyJump) are
 * shadowed or overridden by earlier wildcard stanzas (e.g. Host * / ProxyJump)
 * according to OpenSSH ssh_config(5) first-match-wins semantics.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdbool.h>
#include <ctype.h>

typedef enum {
    PRECEDENCE_OK = 0,
    ERR_SHADOWED_BY_WILDCARD = 1,
    ERR_CONFIG_UNREADABLE = 2
} PrecedenceCheckResult;

/**
 * check_client_precedence:
 * Scans ssh_config for target host and verifies whether target_directive
 * has already been set by an earlier wildcard stanza (e.g. Host *).
 */
PrecedenceCheckResult check_client_precedence(
    const char *config_path,
    const char *target_host,
    const char *target_directive,
    char *out_err_msg,
    size_t err_len
) {
    FILE *fp = fopen(config_path, "r");
    if (!fp) {
        snprintf(out_err_msg, err_len, "Unable to open config file: %s", config_path);
        return ERR_CONFIG_UNREADABLE;
    }

    char line[512];
    bool in_wildcard_block = false;
    bool wildcard_set_directive = false;
    char wildcard_val[128] = {0};
    int line_number = 0;
    int wildcard_line = 0;

    while (fgets(line, sizeof(line), fp)) {
        line_number++;
        char *p = line;
        while (isspace((unsigned char)*p)) p++;
        if (*p == '#' || *p == '\0') continue;

        char key[64] = {0};
        char val[256] = {0};
        if (sscanf(p, "%63s %255s", key, val) < 1) continue;

        if (strcasecmp(key, "Host") == 0) {
            if (strcmp(val, "*") == 0) {
                in_wildcard_block = true;
            } else {
                in_wildcard_block = false;
                if (strcasecmp(val, target_host) == 0 && wildcard_set_directive) {
                    snprintf(
                        out_err_msg,
                        err_len,
                        "Directive '%s' for host '%s' is completely SHADOWED by earlier 'Host *' at line %d (val: '%s')",
                        target_directive,
                        target_host,
                        wildcard_line,
                        wildcard_val
                    );
                    fclose(fp);
                    return ERR_SHADOWED_BY_WILDCARD;
                }
            }
        } else if (in_wildcard_block && strcasecmp(key, target_directive) == 0) {
            wildcard_set_directive = true;
            wildcard_line = line_number;
            strncpy(wildcard_val, val, sizeof(wildcard_val) - 1);
        }
    }

    fclose(fp);
    return PRECEDENCE_OK;
}

int main(int argc, char **argv) {
    const char *cfg = (argc > 1) ? argv[1] : "ssh_config.buggy";
    const char *target = (argc > 2) ? argv[2] : "server2";
    const char *dir = (argc > 3) ? argv[3] : "ProxyJump";

    char err_buf[512] = {0};
    PrecedenceCheckResult res = check_client_precedence(cfg, target, dir, err_buf, sizeof(err_buf));
    if (res != PRECEDENCE_OK) {
        fprintf(stderr, "[PREFLIGHT VIOLATION %d] %s\n", res, err_buf);
        return 1;
    }
    printf("[PREFLIGHT OK] Directive '%s' for host '%s' has valid evaluation precedence.\n", dir, target);
    return 0;
}
