#| symbol-table.jl -- use modules to provide efficient symbol tables

   $Id$

   Copyright (C) 2000 John Harper <john@dcs.warwick.ac.uk>

   This file is part of librep.

   librep is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2, or (at your option)
   any later version.

   librep is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with librep; see the file COPYING.  If not, write to
   the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.
|#

;; Commentary:

;; Structures provide the most efficient means of maintaining mappings
;; from symbols to values (tables using eq? hashing would be comparable,
;; but less efficient since they're more general).

;; However, I don't want to expose the first-class structure interface
;; to general code, hence these wrappers for making anonymous
;; structures

(define-module rep.data.symbol-table

    (export make-symbol-table
	    symbol-table-ref
	    symbol-table-set!
	    symbol-table-bound?
	    symbol-table-for-each)

    (open rep
	  rep.structures)

  (define-module-alias symbol-table rep.data.symbol-table)

  (define (make-symbol-table)
    (make-structure))

  (define (symbol-table-ref table var)
    (and (structure-bound? table var)
	 (structure-ref table var)))

  (define (symbol-table-set! table var value)
    (structure-define table var value))

  (define (symbol-table-bound? table var)
    (structure-bound? table var))

  (define (symbol-table-for-each fun table)
    (structure-for-each fun table)))
