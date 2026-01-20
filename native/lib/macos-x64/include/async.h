/*
 * Copyright (c) 2009-2011, Salvatore Sanfilippo <antirez at gmail dot com>
 * Copyright (c) 2010-2011, Pieter Noordhuis <pcnoordhuis at gmail dot com>
 *
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 * SPDX-FileCopyrightText: 2024 Salvatore Sanfilippo <antirez at gmail dot com>
 * SPDX-FileCopyrightText: 2024 Pieter Noordhuis <pcnoordhuis at gmail dot com>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef __HIREDICT_ASYNC_H
#define __HIREDICT_ASYNC_H
#include "hiredict.h"

#ifdef __cplusplus
extern "C" {
#endif

struct redictAsyncContext; /* need forward declaration of redictAsyncContext */
struct dict; /* dictionary header is included in async.c */

/* Reply callback prototype and container */
typedef void (redictCallbackFn)(struct redictAsyncContext*, void*, void*);
typedef struct redictCallback {
    struct redictCallback *next; /* simple singly linked list */
    redictCallbackFn *fn;
    int pending_subs;
    int unsubscribe_sent;
    void *privdata;
} redictCallback;

/* List of callbacks for either regular replies or pub/sub */
typedef struct redictCallbackList {
    redictCallback *head, *tail;
} redictCallbackList;

/* Connection callback prototypes */
typedef void (redictDisconnectCallback)(const struct redictAsyncContext*, int status);
typedef void (redictConnectCallback)(const struct redictAsyncContext*, int status);
typedef void (redictConnectCallbackNC)(struct redictAsyncContext*, int status);
typedef void (redictTimerCallback)(void *timer, void *privdata);

/* Context for an async connection to Redict */
typedef struct redictAsyncContext {
    /* Hold the regular context, so it can be realloc'ed. */
    redictContext c;

    /* Setup error flags so they can be used directly. */
    int err;
    char *errstr;

    /* Not used by hiredict */
    void *data;
    void (*dataCleanup)(void *privdata);

    /* Event library data and hooks */
    struct {
        void *data;

        /* Hooks that are called when the library expects to start
         * reading/writing. These functions should be idempotent. */
        void (*addRead)(void *privdata);
        void (*delRead)(void *privdata);
        void (*addWrite)(void *privdata);
        void (*delWrite)(void *privdata);
        void (*cleanup)(void *privdata);
        void (*scheduleTimer)(void *privdata, struct timeval tv);
    } ev;

    /* Called when either the connection is terminated due to an error or per
     * user request. The status is set accordingly (REDICT_OK, REDICT_ERR). */
    redictDisconnectCallback *onDisconnect;

    /* Called when the first write event was received. */
    redictConnectCallback *onConnect;
    redictConnectCallbackNC *onConnectNC;

    /* Regular command callbacks */
    redictCallbackList replies;

    /* Address used for connect() */
    struct sockaddr *saddr;
    size_t addrlen;

    /* Subscription callbacks */
    struct {
        redictCallbackList replies;
        struct dict *channels;
        struct dict *patterns;
        int pending_unsubs;
    } sub;

    /* Any configured RESP3 PUSH handler */
    redictAsyncPushFn *push_cb;
} redictAsyncContext;

/* Functions that proxy to hiredict */
redictAsyncContext *redictAsyncConnectWithOptions(const redictOptions *options);
redictAsyncContext *redictAsyncConnect(const char *ip, int port);
redictAsyncContext *redictAsyncConnectBind(const char *ip, int port, const char *source_addr);
redictAsyncContext *redictAsyncConnectBindWithReuse(const char *ip, int port,
                                                  const char *source_addr);
redictAsyncContext *redictAsyncConnectUnix(const char *path);
int redictAsyncSetConnectCallback(redictAsyncContext *ac, redictConnectCallback *fn);
int redictAsyncSetConnectCallbackNC(redictAsyncContext *ac, redictConnectCallbackNC *fn);
int redictAsyncSetDisconnectCallback(redictAsyncContext *ac, redictDisconnectCallback *fn);

redictAsyncPushFn *redictAsyncSetPushCallback(redictAsyncContext *ac, redictAsyncPushFn *fn);
int redictAsyncSetTimeout(redictAsyncContext *ac, struct timeval tv);
void redictAsyncDisconnect(redictAsyncContext *ac);
void redictAsyncFree(redictAsyncContext *ac);

/* Handle read/write events */
void redictAsyncHandleRead(redictAsyncContext *ac);
void redictAsyncHandleWrite(redictAsyncContext *ac);
void redictAsyncHandleTimeout(redictAsyncContext *ac);
void redictAsyncRead(redictAsyncContext *ac);
void redictAsyncWrite(redictAsyncContext *ac);

/* Command functions for an async context. Write the command to the
 * output buffer and register the provided callback. */
int redictvAsyncCommand(redictAsyncContext *ac, redictCallbackFn *fn, void *privdata, const char *format, va_list ap);
int redictAsyncCommand(redictAsyncContext *ac, redictCallbackFn *fn, void *privdata, const char *format, ...);
int redictAsyncCommandArgv(redictAsyncContext *ac, redictCallbackFn *fn, void *privdata, int argc, const char **argv, const size_t *argvlen);
int redictAsyncFormattedCommand(redictAsyncContext *ac, redictCallbackFn *fn, void *privdata, const char *cmd, size_t len);

#ifdef __cplusplus
}
#endif

#endif
