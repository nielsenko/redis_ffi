/*
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef __HIREDIS_ASYNC_H
#define __HIREDIS_ASYNC_H

#include <hiredict/async.h>
#include <hiredis/hiredis.h>

#define redisCallbackFn redictCallbackFn
#define redisCallback redictCallback

/* List of callbacks for either regular replies or pub/sub */
#define redisCallbackList redictCallbackList

/* Connection callback prototypes */
#define redisDisconnectCallback redictDisconnectCallback
#define redisConnectCallback redictConnectCallback
#define redisConnectCallbackNc redictConnectCallbackNC
#define redisTimerCallback redictTimerCallback

/* Context for an async connection to Redict */
#define redisAsyncContext redictAsyncContext

/* Functions that proxy to hiredict */
#define redisAsyncConnectWithOptions redictAsyncConnectWithOptions
#define redisAsyncConnect redictAsyncConnect
#define redisAsyncConnectBind redictAsyncConnectBind
#define redisAsyncConnectBindWithReuse redictAsyncConnectBindWithReuse
#define redisAsyncConnectUnix redictAsyncConnectUnix
#define redisAsyncSetConnectCallback redictAsyncSetConnectCallback
#define redisAsyncSetConnectCallbackNC redictAsyncSetConnectCallbackNC
#define redisAsyncSetDisconnectCallback redictAsyncSetDisconnectCallback

#define redisAsyncSetPushCallback redictAsyncSetPushCallback
#define redisAsyncSetTimeout redictAsyncSetTimeout
#define redisAsyncDisconnect redictAsyncDisconnect
#define redisAsyncFree redictAsyncFree

/* Handle read/write events */
#define redisAsyncHandleRead redictAsyncHandleRead
#define redisAsyncHandleWrite redictAsyncHandleWrite
#define redisAsyncHandleTimeout redictAsyncHandleTimeout
#define redisAsyncRead redictAsyncRead
#define redisAsyncWrite redictAsyncWrite

/* Command functions for an async context. Write the command to the
 * output buffer and register the provided callback. */
#define redisvAsyncCommand redictvAsyncCommand
#define redisAsyncCommand redictAsyncCommand
#define redisAsyncCommandArgv redictAsyncCommandArgv
#define redisAsyncFormattedCommand redictAsyncFormattedCommand

#endif
