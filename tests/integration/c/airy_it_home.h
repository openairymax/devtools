// SPDX-FileCopyrightText: 2026 SPHARX Ltd.
// SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0
// @owner: team-C
/**
 * @file airy_it_home.h
 * @brief 集成测试安装根隔离：每用例自带 AIRY_HOME 临时根
 *
 * daemon_security_init() 与 cupolas_init() 在未显式给出日志目录时回落
 * airy_log_dir()，即 $AIRY_HOME/data/agentrt/logs。此前这些集成用例未设
 * AIRY_HOME，审计事件直写宿主 ~/.airymaxrt，真实审计日志被测试数据污染，
 * 以该日志为判据的运行取证随之失真。
 *
 * 每个用例以 <tmpdir>/airy_it_<tag>_<pid> 建独立安装根并预建日志目录，
 * 事件只落在临时根内。必须在任何 airy_* 调用之前调用 it_home_init()：
 * 路径系统首次解析即缓存结果，事后设置 AIRY_HOME 不会生效。
 */

#ifndef AIRY_IT_HOME_H
#define AIRY_IT_HOME_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <process.h>
#define IT_MKDIR(p) _mkdir(p)
#define IT_SETENV(k, v) _putenv_s((k), (v))
#define IT_PID ((long)_getpid())
#else
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define IT_MKDIR(p) mkdir((p), 0700)
#define IT_SETENV(k, v) setenv((k), (v), 1)
#define IT_PID ((long)getpid())
#endif

static char g_it_home[512];

static int it_mkdir(const char *path)
{
    return (IT_MKDIR(path) != 0 && errno != EEXIST) ? -1 : 0;
}

/* 递归删除临时根；失败仅忽略，用于避免测试残留。 */
static void it_rm(const char *path)
{
#ifdef _WIN32
    char pat[600];
    struct _finddata_t fd;
    intptr_t h;

    snprintf(pat, sizeof(pat), "%s\\*", path);
    h = _findfirst(pat, &fd);
    if (h == -1) {
        _unlink(path);
        _rmdir(path);
        return;
    }
    do {
        char sub[600];

        if (strcmp(fd.name, ".") == 0 || strcmp(fd.name, "..") == 0)
            continue;
        snprintf(sub, sizeof(sub), "%s\\%s", path, fd.name);
        if (fd.attrib & _A_SUBDIR)
            it_rm(sub);
        else
            _unlink(sub);
    } while (_findnext(h, &fd) == 0);
    _findclose(h);
    _rmdir(path);
#else
    DIR *d = opendir(path);
    struct dirent *e;

    if (!d) {
        remove(path);
        return;
    }
    while ((e = readdir(d)) != NULL) {
        char sub[600];

        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
        it_rm(sub);
    }
    closedir(d);
    rmdir(path);
#endif
}

static int it_home_init(const char *tag)
{
    const char *base = getenv("TMPDIR");
    char dir[600];

    if (!base || base[0] == '\0')
        base = getenv("TEMP");
    if (!base || base[0] == '\0')
        base = "/tmp";
    snprintf(g_it_home, sizeof(g_it_home), "%s/airy_it_%s_%ld", base, tag,
             IT_PID);
    if (it_mkdir(g_it_home) != 0)
        return -1;
    snprintf(dir, sizeof(dir), "%s/data", g_it_home);
    if (it_mkdir(dir) != 0)
        return -1;
    snprintf(dir, sizeof(dir), "%s/data/agentrt", g_it_home);
    if (it_mkdir(dir) != 0)
        return -1;
    snprintf(dir, sizeof(dir), "%s/data/agentrt/logs", g_it_home);
    if (it_mkdir(dir) != 0)
        return -1;
    return IT_SETENV("AIRY_HOME", g_it_home) == 0 ? 0 : -1;
}

static void it_home_clean(void)
{
    it_rm(g_it_home);
}

#endif /* AIRY_IT_HOME_H */
