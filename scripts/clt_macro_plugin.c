#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Lightweight Swift compiler plugin for Command Line Tools builds where
// Xcode's proprietary libSwiftUIMacros.dylib and libPreviewsMacros.dylib
// are not bundled in /Library/Developer/CommandLineTools.

static int read_exact(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) return 0;
        got += (size_t)r;
    }
    return 1;
}

static int write_exact(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, p + sent, n - sent);
        if (w <= 0) return 0;
        sent += (size_t)w;
    }
    return 1;
}

static void send_msg(const char *json) {
    uint64_t len = (uint64_t)strlen(json);
    write_exact(STDOUT_FILENO, &len, 8);
    write_exact(STDOUT_FILENO, json, (size_t)len);
}

static int extract_json_string(const char *haystack, const char *key, char *out, size_t out_sz) {
    const char *p = strstr(haystack, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p && (*p == ' ' || *p == '\t' || *p == ':')) p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < out_sz) {
        if (*p == '\\' && p[1]) {
            p++;
            if (*p == 'n') out[i++] = '\n';
            else if (*p == 'r') out[i++] = '\r';
            else if (*p == 't') out[i++] = '\t';
            else out[i++] = *p;
            p++;
        } else {
            out[i++] = *p++;
        }
    }
    out[i] = '\0';
    return 1;
}

static void trim(char *s) {
    char *start = s;
    while (*start && isspace((unsigned char)*start)) start++;
    if (start != s) memmove(s, start, strlen(start) + 1);
    size_t len = strlen(s);
    while (len > 0 && isspace((unsigned char)s[len - 1])) {
        s[--len] = '\0';
    }
}

static void json_escape(const char *in, char *out, size_t out_sz) {
    size_t i = 0;
    while (*in && i + 2 < out_sz) {
        if (*in == '\n') { out[i++] = '\\'; out[i++] = 'n'; }
        else if (*in == '\r') { out[i++] = '\\'; out[i++] = 'r'; }
        else if (*in == '\t') { out[i++] = '\\'; out[i++] = 't'; }
        else if (*in == '"' || *in == '\\') { out[i++] = '\\'; out[i++] = *in; }
        else { out[i++] = *in; }
        in++;
    }
    out[i] = '\0';
}

int main(void) {
    for (;;) {
        uint64_t len = 0;
        if (!read_exact(STDIN_FILENO, &len, 8)) break;
        char *buf = (char *)malloc((size_t)len + 1);
        if (!buf) break;
        if (!read_exact(STDIN_FILENO, buf, (size_t)len)) {
            free(buf);
            break;
        }
        buf[len] = '\0';

        if (strstr(buf, "\"getCapability\"")) {
            send_msg("{\"getCapabilityResult\":{\"capability\":{\"protocolVersion\":1}}}");
        } else if (strstr(buf, "\"expandFreestandingMacro\"")) {
            send_msg("{\"expandMacroResult\":{\"expandedSource\":\"\",\"diagnostics\":[]}}");
        } else if (strstr(buf, "\"expandAttachedMacro\"")) {
            char role[64] = {0};
            extract_json_string(buf, "\"macroRole\"", role, sizeof(role));
            const char *decl = strstr(buf, "\"declSyntax\"");
            char src[4096] = {0};
            if (decl) {
                extract_json_string(decl, "\"source\"", src, sizeof(src));
            }
            char *var_kw = strstr(src, "var ");
            char name[256] = {0}, typ[512] = {0}, defval[1024] = {0};
            if (var_kw) {
                var_kw += 4;
                while (*var_kw && isspace((unsigned char)*var_kw)) var_kw++;
                char *colon = strchr(var_kw, ':');
                if (colon) {
                    size_t nlen = (size_t)(colon - var_kw);
                    if (nlen >= sizeof(name)) nlen = sizeof(name) - 1;
                    memcpy(name, var_kw, nlen);
                    name[nlen] = '\0';
                    trim(name);
                    char *eq = strchr(colon + 1, '=');
                    if (eq) {
                        size_t tlen = (size_t)(eq - (colon + 1));
                        if (tlen >= sizeof(typ)) tlen = sizeof(typ) - 1;
                        memcpy(typ, colon + 1, tlen);
                        typ[tlen] = '\0';
                        trim(typ);
                        strncpy(defval, eq + 1, sizeof(defval) - 1);
                        trim(defval);
                    }
                }
            }
            char expanded[4096] = {0};
            if (strcmp(role, "peer") == 0 && name[0]) {
                snprintf(
                    expanded, sizeof(expanded),
                    "private struct __Key_%s: SwiftUI.EnvironmentKey {\n"
                    "    typealias Value = %s\n"
                    "    static var defaultValue: Value { %s }\n"
                    "}",
                    name, typ, defval
                );
            } else if (strcmp(role, "accessor") == 0 && name[0]) {
                snprintf(
                    expanded, sizeof(expanded),
                    "get {\n"
                    "    self[__Key_%s.self]\n"
                    "}\n"
                    "set {\n"
                    "    self[__Key_%s.self] = newValue\n"
                    "}",
                    name, name
                );
            }
            char escaped[8192] = {0};
            json_escape(expanded, escaped, sizeof(escaped));
            char resp[9000] = {0};
            snprintf(resp, sizeof(resp), "{\"expandMacroResult\":{\"expandedSource\":\"%s\",\"diagnostics\":[]}}", escaped);
            send_msg(resp);
        } else {
            send_msg("{\"expandMacroResult\":{\"expandedSource\":\"\",\"diagnostics\":[]}}");
        }
        free(buf);
    }
    return 0;
}
