/* datums.c -- user-defined opaque types

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

/* Commentary:

   These were inspired by Rees' The Scheme of Things column:

     ftp://ftp.cs.indiana.edu/pub/scheme-repository/doc/pubs/opaque.ps.gz */

#include "repint.h"

/* List of (ID . PRINTER) */
static repv printer_alist;

#define DATUMP(x) rep_CELL8_TYPEP(x, rep_Datum)
#define DATUM(x) ((datum *)rep_PTR (x))

#define DATUM_ID(x) (rep_TUPLE(x)->a)
#define DATUM_VALUE(x) (rep_TUPLE(x)->b)

rep_ALIGN_CELL(rep_tuple rep_eol_datum);
rep_ALIGN_CELL(rep_tuple rep_void_datum);

repv Qnil;


/* type hooks */

static int
datum_cmp(repv d1, repv d2)
{
  if (DATUMP(d1) && DATUMP(d2) && DATUM_ID(d1) == DATUM_ID(d2)) {
    return rep_value_cmp(DATUM_VALUE(d1), DATUM_VALUE(d2));
  } else {
    return 1;
  }
}

static void
datum_print(repv stream, repv arg)
{    
  if (arg == rep_nil) {
    DEFSTRING(eol, "()");
    rep_stream_puts(stream, rep_PTR(rep_VAL(&eol)), 2, true);
  } else if (arg == rep_void) {
    DEFSTRING(eol, "#<void>");
    rep_stream_puts(stream, rep_PTR(rep_VAL(&eol)), 2, true);
  } else {
    repv printer = Fassq(DATUM_ID(arg), printer_alist);
    if (printer && rep_CONSP(printer) && rep_CDR(printer) != rep_nil) {
      rep_call_lisp2(rep_CDR(printer), arg, stream);
    } else if (rep_SYMBOLP(DATUM_ID(arg))) {
      rep_stream_puts(stream, "#<datum ", -1, false);
      rep_stream_puts(stream, rep_PTR(rep_SYM(DATUM_ID(arg))->name), -1, true);
      rep_stream_putc(stream, '>');
    } else {
      rep_stream_puts(stream, "#<datum>", -1, false);
    }
  }
}


/* lisp functions */

DEFUN("make-datum", Fmake_datum,
      Smake_datum, (repv value, repv id), rep_Subr2) /*
::doc:rep.data.datums#make-datum::
make-datum VALUE ID

Create and return a new data object of type ID (an arbitrary value), it
will have object VALUE associated with it.
::end:: */
{
  return rep_make_tuple(rep_Datum, id, value);
}

DEFUN("define-datum-printer", Fdefine_datum_printer,
      Sdefine_datum_printer, (repv id, repv printer), rep_Subr2) /*
::doc:rep.data.datums#define-datum-printer::
define-datum-printer ID PRINTER

Register a custom printer for all datums with type ID. When these
objects printed are, the function PRINTER will be called with two
arguments, the datum and the stream to print to.
::end:: */
{
  repv cell = Fassq(id, printer_alist);
  if (cell && rep_CONSP(cell)) {
    rep_CDR(cell) = printer;
  } else {
    printer_alist = Fcons(Fcons(id, printer), printer_alist);
  }
  return printer;
}

DEFUN("datum-ref", Fdatum_ref, Sdatum_ref, (repv obj, repv id), rep_Subr2) /*
::doc:rep.data.datums#datum-ref::
datum-ref DATUM ID

If data object DATUM has type ID, return its associated value, else
signal an error.
::end:: */
{
  rep_DECLARE(1, obj, DATUMP(obj) && DATUM_ID(obj) == id);

  return DATUM_VALUE(obj);
}

DEFUN("datum-set!", Fdatum_set, Sdatum_set,
      (repv obj, repv id, repv value), rep_Subr3) /*
::doc:rep.data.datums#datum-set!::
datum-set! DATUM ID VALUE

If data object DATUM has type ID, modify its associated value to be
VALUE, else signal an error.
::end:: */
{
  rep_DECLARE(1, obj, DATUMP(obj) && DATUM_ID(obj) == id);

  DATUM_VALUE(obj) = value;

  return rep_undefined_value;
}

DEFUN("datum?", Fhas_type_p,
      Shas_type_p, (repv arg, repv id), rep_Subr2) /*
::doc:rep.data.datums#datum?::
datum? ARG ID

Return `t' if object ARG has data type ID (and thus was initially
created using the `make-datum' function).
::end:: */
{
  return DATUMP(arg) && DATUM_ID(arg) == id ? Qt : rep_nil;
}


/* dl hooks */

void
rep_pre_datums_init(void)
{
  static rep_type datum = {
    .car = rep_Datum,
    .name = "datum",
    .compare = datum_cmp,
    .print = datum_print,
    .mark = rep_mark_tuple,
  };

  rep_define_type(&datum);

  /* Including CELL_MARK_BIT means we don't have to worry about GC; the
     cell will never get remarked, and it's not on any allocation lists
     to get swept up from. */

  rep_eol_datum.car = rep_Datum | rep_CELL_STATIC_BIT | rep_CELL_MARK_BIT;
  rep_eol_datum.a = rep_VAL(&rep_eol_datum);
  rep_eol_datum.b = rep_VAL(&rep_eol_datum);

  rep_void_datum.car = rep_Datum | rep_CELL_STATIC_BIT | rep_CELL_MARK_BIT;
  rep_void_datum.a = rep_VAL(&rep_void_datum);
  rep_void_datum.b = rep_VAL(&rep_void_datum);

  Qnil = rep_nil;
}

void
rep_datums_init(void)
{
  repv tem = rep_push_structure("rep.data.datums");

  rep_ADD_SUBR(Smake_datum);
  rep_ADD_SUBR(Sdefine_datum_printer);
  rep_ADD_SUBR(Sdatum_ref);
  rep_ADD_SUBR(Sdatum_set);
  rep_ADD_SUBR(Shas_type_p);

  printer_alist = rep_nil;
  rep_mark_static(&printer_alist);

  rep_pop_structure(tem);
}
