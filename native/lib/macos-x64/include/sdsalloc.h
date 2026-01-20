/* SDSLib 2.0 -- A C dynamic strings library
 *
 * Copyright (c) 2006-2015, Salvatore Sanfilippo <antirez at gmail dot com>
 * Copyright (c) 2015, Oran Agra
 * Copyright (c) 2015, Redis Labs, Inc
 *
 * SPDX-FileCopyrightText: 2024 Hiredict Contributors
 * SPDX-FileCopyrightText: 2024 Salvatore Sanfilippo <antirez at gmail dot com>
 * SPDX-FileCopyrightText: 2024 Oran Agra
 * SPDX-FileCopyrightText: 2024 Redis Labs, Inc
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 */

/* SDS allocator selection.
 *
 * This file is used in order to change the SDS allocator at compile time.
 * Just define the following defines to what you want to use. Also add
 * the include of your alternate allocator if needed (not needed in order
 * to use the default libc allocator). */

#include "alloc.h"

#define s_malloc hi_malloc
#define s_realloc hi_realloc
#define s_free hi_free
