/*
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

#ifndef __HIREDIS_ALLOC_H
#define __HIREDIS_ALLOC_H

#include <hiredict/alloc.h>

/* Structure pointing to our actually configured allocators */
#define hiredisAllocFuncs hiredictAllocFuncs

#define hiredisSetAllocators hiredictSetAllocators
#define hiredisResetAllocators hiredictResetAllocators

#ifndef _WIN32
#define hiredisAllocFns hiredictAllocFns;
#endif

#endif /* HIREDIS_ALLOC_H */
