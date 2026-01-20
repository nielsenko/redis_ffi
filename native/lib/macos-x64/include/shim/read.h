/*
 *
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef __HIREDIS_READ_H
#define __HIREDIS_READ_H

#include <hiredict/read.h>

#define REDIS_ERR REDICT_ERR
#define REDIS_OK REDICT_OK

/* When an error occurs, the err flag in a context is set to hold the type of
 * error that occurred. REDICT_ERR_IO means there was an I/O error and you
 * should use the "errno" variable to find out what is wrong.
 * For other values, the "errstr" field will hold a description. */
#define REDIS_ERR_IO REDICT_ERR_IO /* Error in read or write */
#define REDIS_ERR_EOF REDICT_ERR_EOF /* End of file */
#define REDIS_ERR_PROTOCOL REDICT_ERR_PROTOCOL /* Protocol error */
#define REDIS_ERR_OOM REDICT_ERR_OOM /* Out of memory */
#define REDIS_ERR_TIMEOUT REDICT_ERR_TIMEOUT /* Timed out */
#define REDIS_ERR_OTHER REDICT_ERR_OTHER /* Everything else... */

#define REDIS_REPLY_STRING REDICT_REPLY_STRING
#define REDIS_REPLY_ARRAY REDICT_REPLY_ARRAY
#define REDIS_REPLY_INTEGER REDICT_REPLY_INTEGER
#define REDIS_REPLY_NIL REDICT_REPLY_NIL
#define REDIS_REPLY_STATUS REDICT_REPLY_STATUS
#define REDIS_REPLY_ERROR REDICT_REPLY_ERROR
#define REDIS_REPLY_DOUBLE REDICT_REPLY_DOUBLE
#define REDIS_REPLY_BOOL REDICT_REPLY_BOOL
#define REDIS_REPLY_MAP REDICT_REPLY_MAP
#define REDIS_REPLY_SET REDICT_REPLY_SET
#define REDIS_REPLY_ATTR REDICT_REPLY_ATTR
#define REDIS_REPLY_PUSH REDICT_REPLY_PUSH
#define REDIS_REPLY_BIGNUM REDICT_REPLY_BIGNUM
#define REDIS_REPLY_VERB REDICT_REPLY_VERB

/* Default max unused reader buffer. */
#define REDIS_READER_MAX_BUF REDICT_READER_MAX_BUF

/* Default multi-bulk element limit */
#define REDIS_READER_MAX_ARRAY_ELEMENTS REDICT_READER_MAX_ARRAY_ELEMENTS

#define redisReadTask redictReadTask
#define redisReplyObjectFunctions redictReplyObjectFunctions
#define redisReader redictReader

/* Public API for the protocol parser. */
#define redisReaderCreateWithFunctions redictReaderCreateWithFunctions
#define redisReaderFree redictReaderFree
#define redisReaderFeed redictReaderFeed
#define redisReaderGetReply redictReaderGetReply

#define redisReaderSetPrivdata(_r, _p) redictReaderSetPrivdata(_r, _p)
#define redisReaderGetObject(_r) redictReaderGetObject(_r)
#define redisReaderGetError(_r) redictReaderGetError(_r)

#endif
