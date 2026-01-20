/* Extracted from anet.c to work properly with Hiredict error reporting.
 *
 * Copyright (c) 2009-2011, Salvatore Sanfilippo <antirez at gmail dot com>
 * Copyright (c) 2010-2014, Pieter Noordhuis <pcnoordhuis at gmail dot com>
 * Copyright (c) 2015, Matt Stancliff <matt at genges dot com>,
 *                     Jan-Erik Rediger <janerik at fnordig dot com>
 *
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 * SPDX-FileCopyrightText: 2024 Salvatore Sanfilippo <antirez at gmail dot com>
 * SPDX-FileCopyrightText: 2024 Pieter Noordhuis <pcnoordhuis at gmail dot com>
 * SPDX-FileCopyrightText: 2024 Matt Stancliff <matt at genges dot com>
 * SPDX-FileCopyrightText: 2024 Jan-Erik Rediger <janerik at fnordig dot com>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef __NET_H
#define __NET_H

#include "hiredict.h"

void redictNetClose(redictContext *c);
ssize_t redictNetRead(redictContext *c, char *buf, size_t bufcap);
ssize_t redictNetWrite(redictContext *c);

int redictCheckSocketError(redictContext *c);
int redictContextSetTimeout(redictContext *c, const struct timeval tv);
int redictContextConnectTcp(redictContext *c, const char *addr, int port, const struct timeval *timeout);
int redictContextConnectBindTcp(redictContext *c, const char *addr, int port,
                               const struct timeval *timeout,
                               const char *source_addr);
int redictContextConnectUnix(redictContext *c, const char *path, const struct timeval *timeout);
int redictKeepAlive(redictContext *c, int interval);
int redictCheckConnectDone(redictContext *c, int *completed);

int redictSetTcpNoDelay(redictContext *c);
int redictContextSetTcpUserTimeout(redictContext *c, unsigned int timeout);

#endif
