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


#ifndef __HIREDICT_READ_H
#define __HIREDICT_READ_H
#include <stdio.h> /* for size_t */

#define REDICT_ERR -1
#define REDICT_OK 0

/* When an error occurs, the err flag in a context is set to hold the type of
 * error that occurred. REDICT_ERR_IO means there was an I/O error and you
 * should use the "errno" variable to find out what is wrong.
 * For other values, the "errstr" field will hold a description. */
#define REDICT_ERR_IO 1 /* Error in read or write */
#define REDICT_ERR_EOF 3 /* End of file */
#define REDICT_ERR_PROTOCOL 4 /* Protocol error */
#define REDICT_ERR_OOM 5 /* Out of memory */
#define REDICT_ERR_TIMEOUT 6 /* Timed out */
#define REDICT_ERR_OTHER 2 /* Everything else... */

#define REDICT_REPLY_STRING 1
#define REDICT_REPLY_ARRAY 2
#define REDICT_REPLY_INTEGER 3
#define REDICT_REPLY_NIL 4
#define REDICT_REPLY_STATUS 5
#define REDICT_REPLY_ERROR 6
#define REDICT_REPLY_DOUBLE 7
#define REDICT_REPLY_BOOL 8
#define REDICT_REPLY_MAP 9
#define REDICT_REPLY_SET 10
#define REDICT_REPLY_ATTR 11
#define REDICT_REPLY_PUSH 12
#define REDICT_REPLY_BIGNUM 13
#define REDICT_REPLY_VERB 14

/* Default max unused reader buffer. */
#define REDICT_READER_MAX_BUF (1024*16)

/* Default multi-bulk element limit */
#define REDICT_READER_MAX_ARRAY_ELEMENTS ((1LL<<32) - 1)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct redictReadTask {
    int type;
    long long elements; /* number of elements in multibulk container */
    int idx; /* index in parent (array) object */
    void *obj; /* holds user-generated value for a read task */
    struct redictReadTask *parent; /* parent task */
    void *privdata; /* user-settable arbitrary field */
} redictReadTask;

typedef struct redictReplyObjectFunctions {
    void *(*createString)(const redictReadTask*, char*, size_t);
    void *(*createArray)(const redictReadTask*, size_t);
    void *(*createInteger)(const redictReadTask*, long long);
    void *(*createDouble)(const redictReadTask*, double, char*, size_t);
    void *(*createNil)(const redictReadTask*);
    void *(*createBool)(const redictReadTask*, int);
    void (*freeObject)(void*);
} redictReplyObjectFunctions;

typedef struct redictReader {
    int err; /* Error flags, 0 when there is no error */
    char errstr[128]; /* String representation of error when applicable */

    char *buf; /* Read buffer */
    size_t pos; /* Buffer cursor */
    size_t len; /* Buffer length */
    size_t maxbuf; /* Max length of unused buffer */
    long long maxelements; /* Max multi-bulk elements */

    redictReadTask **task;
    int tasks;

    int ridx; /* Index of current read task */
    void *reply; /* Temporary reply pointer */

    redictReplyObjectFunctions *fn;
    void *privdata;
} redictReader;

/* Public API for the protocol parser. */
redictReader *redictReaderCreateWithFunctions(redictReplyObjectFunctions *fn);
void redictReaderFree(redictReader *r);
int redictReaderFeed(redictReader *r, const char *buf, size_t len);
int redictReaderGetReply(redictReader *r, void **reply);

#define redictReaderSetPrivdata(_r, _p) (int)(((redictReader*)(_r))->privdata = (_p))
#define redictReaderGetObject(_r) (((redictReader*)(_r))->reply)
#define redictReaderGetError(_r) (((redictReader*)(_r))->errstr)

#ifdef __cplusplus
}
#endif

#endif
