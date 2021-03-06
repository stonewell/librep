/* vectors.c -- vector functions

   Copyright (C) 1993-2015 John Harper <jsh@unfactored.org>

   This file is part of Librep.

   Librep is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   Librep is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with Librep; see the file COPYING.  If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.  */

#include "repint.h"

#include <string.h>

#ifdef NEED_MEMORY_H
# include <memory.h>
#endif

static rep_vector *vector_list;

int rep_used_vector_slots;

repv
rep_make_vector(int size)
{
  int len = rep_VECT_SIZEOF(size);
  rep_vector *v = rep_alloc(len);
  if (v) {
    v->car = rep_Vector | (size << rep_VECTOR_LEN_SHIFT);
    v->next = vector_list;
    vector_list = v;
    rep_used_vector_slots += size;
    rep_data_after_gc += len;
  }
  return rep_VAL(v);
}

void
rep_vector_sweep(void)
{
  rep_vector *ptr = vector_list;
  vector_list = NULL;

  rep_used_vector_slots = 0;

  while (ptr) {
    rep_vector *next = ptr->next;
    if (!rep_GC_CELL_MARKEDP(rep_VAL(ptr))) {
      rep_free(ptr);
    } else {
      ptr->next = vector_list;
      vector_list = ptr;
      rep_used_vector_slots += rep_VECTOR_LEN(ptr);
      rep_GC_CLR_CELL(rep_VAL(ptr));
    }
    ptr = next;
  }
}

int
rep_vector_cmp(repv v1, repv v2)
{
  if (rep_TYPE(v1) != rep_TYPE(v2) || rep_VECTOR_LEN(v1) != rep_VECTOR_LEN(v2)) {
    return 1;
  }

  int len = rep_VECTOR_LEN(v1);

  int ret = 0;

  for(int i = 0; ret == 0 && i < len; i++) {
    ret = rep_value_cmp(rep_VECTI(v1, i), rep_VECTI(v2, i));
  }

  return ret;
}

DEFUN("vector", Fvector, Svector, (int argc, repv *argv), rep_SubrV) /*
::doc:rep.data#vector::
vector ARGS...

Returns a new vector with ARGS... as its elements.
::end:: */
{
  repv vec = rep_make_vector(argc);

  if (!vec) {
    return rep_mem_error();
  }

  memcpy(rep_VECT(vec)->array, argv, argc * sizeof(repv));

  return vec;
}

DEFUN("make-vector", Fmake_vector,
      Smake_vector, (repv size, repv init), rep_Subr2) /*
::doc:rep.data#make-vector::
make-vector SIZE [INITIAL-VALUE]

Creates a new vector of size SIZE. If INITIAL-VALUE is provided each element
will be set to that value, else they will all be nil.
::end:: */
{
  rep_DECLARE1(size, rep_NON_NEG_INT_P);

  repv vec = rep_make_vector(rep_INT(size));

  if (!vec) {
    return rep_mem_error();
  }

  for (intptr_t i = 0; i < rep_INT(size); i++) {
    rep_VECTI(vec, i) = init;
  }

  return vec;
}

DEFUN("vector-length", Fvector_length,
      Svector_length, (repv vec), rep_Subr1) /*
::doc:rep.data#vector-length::
vector-length VECTOR

Returns the number of elements in VECTOR.
::end:: */
{
  rep_DECLARE1(vec, rep_VECTOR_OR_BYTECODE_P);

  return rep_MAKE_INT(rep_VECTOR_LEN(vec));
}

DEFUN("vector-ref", Fvector_ref,
      Svector_ref, (repv vec, repv idx), rep_Subr2) /*
::doc:rep.data#vector-ref::
vector-ref VECTOR INDEX

Returns the INDEX'th elemnt of VECTOR.
::end:: */
{
  rep_DECLARE1(vec, rep_VECTOR_OR_BYTECODE_P);
  rep_DECLARE2(idx, rep_NON_NEG_INT_P);

  if (rep_INT(idx) >= rep_VECTOR_LEN(vec)) { 
    return rep_signal_arg_error (idx, 2);
  }

  return rep_VECTI(vec, rep_INT(idx));
}

DEFUN("vector-set!", Fvector_set,
      Svector_set, (repv vec, repv idx, repv value), rep_Subr3) /*
::doc:rep.data#vector-set!::
vector-set! VECTOR INDEX VALUE

Sets the INDEX'th element of VECTOR to VALUE.
::end:: */
{
  rep_DECLARE1(vec, rep_VECTOR_OR_BYTECODE_P);
  rep_DECLARE2(idx, rep_NON_NEG_INT_P);

  if (!rep_VECTOR_WRITABLE_P(vec)) {
    return Fsignal(Qsetting_constant, rep_LIST_1(vec));
  }

  if (rep_INT(idx) >= rep_VECTOR_LEN(vec)) { 
    return rep_signal_arg_error (idx, 2);
  }

  rep_VECTI(vec, rep_INT(idx)) = value;

  return rep_undefined_value;
}

DEFUN("make-vector-immutable!", Fmake_vector_immutable,
      Smake_vector_immutable, (repv vec), rep_Subr1) /*
::doc:rep.data#make-vector-immutable!::
make-vector-immutable! VECTOR

Marks that the contents of VECTOR may no longer be modified.
::end:: */
{
  rep_DECLARE1(vec, rep_VECTORP);

  rep_VECT(vec)->car |= rep_VECTOR_IMMUTABLE;

  return rep_undefined_value;
}

DEFUN("list->vector", Flist_to_vector,
      Slist_to_vector, (repv lst), rep_Subr1) /*
::doc:rep.data#list->vector::
list->vector LIST

Creates a new vector with elements from LIST.
::end:: */
{
  rep_DECLARE1(lst, rep_LISTP);

  int count = rep_list_length(lst);
  if (count < 0) {
    return 0;
  }

  repv vec = rep_make_vector(count);

  if (!vec) {
    return rep_mem_error();
  }

  for (int i = 0; i < count; i++) {
    rep_VECTI(vec, i) = rep_CAR(lst);
    lst = rep_CDR(lst);
  }

  return vec;
}

DEFUN("vector->list", Fvector_to_list,
      Svector_to_list, (repv vec), rep_Subr1) /*
::doc:rep.data#vector->list::
vector->list VECTOR

Creates a new list with elements from VECTOR.
::end:: */
{
  rep_DECLARE1(vec, rep_VECTORP);

  int count = rep_VECTOR_LEN(vec);

  repv ret = rep_nil;
  repv *tail = &ret;

  for (int i = 0; i < count; i++) {
    repv cell = Fcons(rep_VECTI(vec, i), rep_nil);
    *tail = cell;
    tail = rep_CDRLOC(cell);
  }

  return ret;
}

DEFUN("vector-map", Fvector_map, Svector_map,
      (int argc, repv *argv), rep_SubrV) /*
::doc:rep.data#vector-map::
vector-map FUNCTION VECTORS...

Calls FUNCTION with groups of elements from VECTORS, returning a new
vector with the results. If more than one vector is provided, the
smallest vector terminates the function.
::end:: */
{
  if (argc < 2) {
    return rep_signal_missing_arg(argc + 1);
  }

  intptr_t length = INTPTR_MAX;

  for (int i = 1; i < argc; i++) {
    rep_DECLARE(i + 1, argv[i], rep_VECTORP(argv[i]));
    intptr_t li = rep_VECTOR_LEN(argv[i]);
    if (li < length) {
      length = li;
    }
  }

  repv ret = rep_make_vector(length);

  if (!ret) {
    return rep_mem_error();
  }

  rep_GC_root gc_ret;
  rep_GC_n_roots gc_argv;
  rep_PUSHGC(gc_ret, ret);
  rep_PUSHGCN(gc_argv, argv, argc);

  for (intptr_t j = 0; j < length; j++) {
    repv elts[argc-1];
    for (int i = 1; i < argc; i++) {
      elts[i-1] = rep_VECTI(argv[i], j);
    }

    repv tem = rep_call_lispn(argv[0], argc - 1, elts);
    if (!tem) {
      ret = 0;
      break;
    }

    rep_VECTI(ret, j) = tem;
  }

  rep_POPGCN;
  rep_POPGC;

  return ret;
}

DEFUN("vector-for-each", Fvector_for_each, Svector_for_each,
      (int argc, repv *argv), rep_SubrV) /*
::doc:rep.data#vector-for-each::
vector-for-each FUNCTION VECTORS...

Calls FUNCTION with groups of elements from VECTORS. If more than one
vector is provided, the smallest vector terminates the function.
::end:: */
{
  if (argc < 2) {
    return rep_signal_missing_arg(argc + 1);
  }

  intptr_t length = INTPTR_MAX;

  for (int i = 1; i < argc; i++) {
    rep_DECLARE(i + 1, argv[i], rep_VECTORP(argv[i]));
    int li = rep_VECTOR_LEN(argv[i]);
    if (li < length) {
      length = li;
    }
  }

  repv ret = rep_undefined_value;

  rep_GC_n_roots gc_argv;
  rep_PUSHGCN(gc_argv, argv, argc);

  for (intptr_t j = 0; j < length; j++) {
    repv elts[argc-1];
    for (int i = 1; i < argc; i++) {
      elts[i-1] = rep_VECTI(argv[i], j);
    }

    if (!rep_call_lispn(argv[0], argc - 1, elts)) {
      ret = 0;
      break;
    }
  }

  rep_POPGCN;

  return ret;
}

DEFUN("vector?", Fvectorp, Svectorp, (repv arg), rep_Subr1) /*
::doc:rep.data#vector?::
vector? ARG

Returns t if ARG is a vector.
::end:: */
{
  return rep_VECTORP(arg) ? Qt : rep_nil;
}

void
rep_vectors_init(void)
{
  repv tem = rep_push_structure("rep.data");
  rep_ADD_SUBR(Svector);
  rep_ADD_SUBR(Smake_vector);
  rep_ADD_SUBR(Svector_length);
  rep_ADD_SUBR(Svector_ref);
  rep_ADD_SUBR(Svector_set);
  rep_ADD_SUBR(Smake_vector_immutable);
  rep_ADD_SUBR(Slist_to_vector);
  rep_ADD_SUBR(Svector_to_list);
  rep_ADD_SUBR(Svector_map);
  rep_ADD_SUBR(Svector_for_each);
  rep_ADD_SUBR(Svectorp);
  rep_pop_structure(tem);
}

void
rep_vectors_kill(void)
{
  rep_vector *ptr = vector_list;

  vector_list = NULL;
  rep_used_vector_slots = 0;

  while (ptr) {
    rep_vector *next = ptr->next;
    rep_free(ptr);
    ptr = next;
  }
}
