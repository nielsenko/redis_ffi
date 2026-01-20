/*
 * Copyright (c) 2020, Michael Grunder <michael dot grunder at gmail dot com>
 *
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 * SPDX-FileCopyrightText: 2024 Michael Grunder <michael dot grunder at gmail dot com>
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef HIREDICT_ALLOC_H
#define HIREDICT_ALLOC_H

#include <stddef.h> /* for size_t */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Structure pointing to our actually configured allocators */
typedef struct hiredictAllocFuncs {
    void *(*mallocFn)(size_t);
    void *(*callocFn)(size_t,size_t);
    void *(*reallocFn)(void*,size_t);
    char *(*strdupFn)(const char*);
    void (*freeFn)(void*);
} hiredictAllocFuncs;

hiredictAllocFuncs hiredictSetAllocators(hiredictAllocFuncs *ha);
void hiredictResetAllocators(void);

#ifndef _WIN32

/* Hiredict' configured allocator function pointer struct */
extern hiredictAllocFuncs hiredictAllocFns;

static inline void *hi_malloc(size_t size) {
    return hiredictAllocFns.mallocFn(size);
}

static inline void *hi_calloc(size_t nmemb, size_t size) {
    /* Overflow check as the user can specify any arbitrary allocator */
    if (SIZE_MAX / size < nmemb)
        return NULL;

    return hiredictAllocFns.callocFn(nmemb, size);
}

static inline void *hi_realloc(void *ptr, size_t size) {
    return hiredictAllocFns.reallocFn(ptr, size);
}

static inline char *hi_strdup(const char *str) {
    return hiredictAllocFns.strdupFn(str);
}

static inline void hi_free(void *ptr) {
    hiredictAllocFns.freeFn(ptr);
}

#else

void *hi_malloc(size_t size);
void *hi_calloc(size_t nmemb, size_t size);
void *hi_realloc(void *ptr, size_t size);
char *hi_strdup(const char *str);
void hi_free(void *ptr);

#endif

#ifdef __cplusplus
}
#endif

#endif /* HIREDICT_ALLOC_H */
