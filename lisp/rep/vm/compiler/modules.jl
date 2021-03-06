#| modules.jl -- module handling for the compiler

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

(define-module rep.vm.compiler.modules

    (export current-module
	    macro-env
	    variable-ref?
	    locate-variable
	    compiler-variable-ref
	    compiler-bound?
	    compiler-binding-from-rep?
	    compiler-binding-immutable?
	    get-procedure-handler
	    get-language-property
	    compiler-macroexpand
	    compiler-macroexpand-1
	    compile-module-body
	    note-require
	    note-macro-def
	    compile-anonymous-module
	    compile-define-module
	    compile-top-level-module
	    compile-top-level-define-module
	    compile-module-ref
	    compile-function
	    compile-module)

    (open rep
	  rep.structures
	  rep.vm.compiler.basic
	  rep.vm.compiler.bindings
	  rep.vm.compiler.utils
	  rep.vm.compiler.lap)

  (define macro-env (make-fluid '()))		;alist of (NAME . MACRO-DEF)
  (define default-macro-env (make-fluid '()))

  ;; the name of the module containing what is being compiled

  (define current-module (make-fluid *user-module*))

  ;; if true, the namespace of the module containing what is being
  ;; compiled in; only set when compiling code outside a module
  ;; definition

  (define current-structure (make-fluid
			     (find-structure (fluid-ref current-module))))

  (define current-language (make-fluid 'rep))

  ;; the names of the currently open and accessed modules

  (define open-modules (make-fluid (and (fluid-ref current-structure)
					(structure-imports
					 (fluid-ref current-structure)))))
  (define accessed-modules (make-fluid (and (fluid-ref current-structure)
					    (structure-accessible
					     (fluid-ref current-structure)))))

  (define (intern-structure-safely name)
    (condition-case nil
	(intern-structure name)
      (file-error nil)))

  ;; return t if the module called STRUCT exports a variable called VAR

  (defun module-exports? (struct var)
    (and (symbol? var)
	 (cond ((symbol? struct)
		(let ((tem (intern-structure-safely struct)))
		  (and tem (structure-exports? tem var))))
	       ((structure? struct)
		(structure-exports? struct var)))))

  ;; return t if ARG is a structure reference form

  (defun module-ref? (arg)
    (and (eq? (car arg) 'module-ref)
	 (memq (locate-variable 'module-ref) '(rep rep.module-system))))

  ;; return t if ARG refers to a variable

  (defun variable-ref? (arg)
    (or (symbol? arg) (module-ref? arg)))

  ;; return the name of the structure exporting VAR to the current
  ;; structure, or nil

  (defun locate-variable (var)
    (if (module-ref? var)
	(list-ref var 1)
      (let loop ((rest (fluid-ref open-modules)))
	(if rest
	    (if (module-exports? (car rest) var)
		(car rest)
	      (loop (cdr rest)))
	  ;; it's not exported by any opened modules, if we have a handle
	  ;; on the current module (i.e. we're compiling code not in
	  ;; a module definition) try looking in that
	  (if (and (symbol? var) (fluid-ref current-structure)
		   (structure-bound? (fluid-ref current-structure) var))
	      (fluid-ref current-module)
	    nil)))))

  (defun variable-stem (var)
    (if (pair? var)
	(list-ref var 2)		;module-ref
      var))

  (defun variable-ref-1 (var)
    (cond ((and (symbol? var) (special-variable? var) (variable-bound? var))
	   (variable-ref var))
	  ((and (symbol? var) (fluid-ref current-structure)
		(structure-bound? (fluid-ref current-structure) var))
	   (structure-ref (fluid-ref current-structure) var))
	  ((has-local-binding? var) nil)
	  (t
	   (let* ((struct (locate-variable var))
		  (module (and struct (intern-structure-safely struct))))
	     (and module
		  (structure-bound? module (variable-stem var))
		  (structure-ref module (variable-stem var)))))))

  ;; if possible, return the value of variable VAR, else return nil

  (defun compiler-variable-ref (var)
    (let ((value (variable-ref-1 var)))
      ;; if the value is an autoload, try to load it
      (if (and (closure? value)
	       (eq? (car (closure-function value)) 'autoload))
	  (load-autoload value)
	value)))

  (defun compiler-bound? (var)
    (and (symbol? var)
	 (if (special-variable? var)
	     (variable-bound? var)
	   (locate-variable var))))

  ;; return t if the binding of VAR comes from the rep (built-ins) module

  (defun compiler-binding-from-rep? (var)
    (if (module-ref? var)
	(eq? (list-ref var 1) 'rep)
      (and (not (has-local-binding? var))
	   (eq? (locate-variable var) 'rep))))

  ;; return t if the binding of VAR is a known constant
  ;; (not including those in comp-constant-env)

  (defun compiler-binding-immutable? (var)
    (and (not (has-local-binding? var))
	 (let ((struct (locate-variable var)))
	   (and struct (binding-immutable? (variable-stem var)
					    (intern-structure-safely struct))))))

  (defun get-language-property (prop)
    (and (fluid-ref current-language) (get (fluid-ref current-language) prop)))

  (defun get-procedure-handler (name prop-name)
    (unless (has-local-binding? name)
      (let*
	  ((struct (locate-variable name))
	   (prop (and struct (get struct prop-name))))
	(if (and prop (symbol? prop))
	    (get (variable-stem name) prop)
	  prop))))

  (defun compiler-macroexpand-1 (form)
    (when (and (pair? form)
	       (symbol? (car form))
	       (not (has-local-binding? (car form))))
      (let* ((def (assq (car form) (fluid-ref macro-env)))
	     ;; make #<subr macroexpand> pass us any inner expansions
	     (*macro-environment* compiler-macroexpand-1))
	(if def
	    (set! form (apply (cdr def) (cdr form)))
	  (set! def (compiler-variable-ref (car form)))
	  (when (and (eq? (car def) 'macro) (function? (cdr def)))
	    (when (and (closure? (cdr def))
		       (eq? (car (closure-function (cdr def))) 'autoload))
	      (set! def (load-autoload (cdr def))))
	    (set! form (apply (cdr def) (cdr form)))))))
    form)

  (defun compiler-macroexpand (form #!optional pred)
    (let loop ((in form))
      (let
	  ((out (compiler-macroexpand-1 in)))
	;;(format *standard-error* "in: %S, out: %S\n" in out)
	(if ((or pred eq?) in out)
	    out
	  (loop out)))))

  ;; if OPENED or ACCESSED are `t', the current values are used

  (defun call-with-module-env (thunk opened accessed)
    (let-fluids ((macro-env (fluid-ref default-macro-env))
		 (current-module (fluid-ref current-module))
		 (current-structure (fluid-ref current-structure))
		 (current-language (fluid-ref current-language))
		 (open-modules (if (eq? opened t)
				   (fluid-ref open-modules)
				 opened))
		 (accessed-modules (if (eq? accessed t)
				       (fluid-ref accessed-modules)
				     accessed))
		 (const-env nil)
		 (inline-env nil)
		 (defuns nil)
		 (defvars (fluid-ref defvars))
		 (defines nil)
		 (output-stream nil))
      (thunk)))

  (defun compile-module-body-1 (body)
    (find-language-module)

    ;; find language pass-1 and pass-2 compilers
    (let ((pass-1 (get-language-property 'compiler-pass-1))
	  (pass-2 (get-language-property 'compiler-pass-2)))

      ;; pass 1. remember definitions in the body for pass 2
      (when pass-1
	(set! body (pass-1 body)))

      ;; pass 2. the actual compilation
      (when pass-2
	(set! body (pass-2 body)))

      ;; return the compiled representation of the body
      body))

  (defun compile-module-body (body opened accessed)
    (call-with-module-env
     (lambda () (compile-module-body-1 body))
     opened accessed))

  (defun note-require (feature)
    (unless (or (memq feature (fluid-ref open-modules))
		(and (fluid-ref current-structure)
		     (eval `(feature? ',feature)
			   (fluid-ref current-structure))))

      ;; FIXME: this is broken; there's no way to tell if we're trying
      ;; to load a module, or a bare file.

      (cond ((find-structure feature)
	     ;; structure already loaded..
	     (fluid-set! open-modules (cons feature (fluid-ref open-modules))))

	    ((fluid-ref current-structure)
	     ;; try to require it..
	     (eval `(require ',feature) (fluid-ref current-structure))
	     (when (find-structure feature)
	       (fluid-set! open-modules (cons feature
					      (fluid-ref open-modules)))))

	    ;; no current structure, try to load the file
	    ;; as a module..
	    ((intern-structure feature)
	     (fluid-set! open-modules (cons feature (fluid-ref open-modules))))

	    (t (compiler-warning "unable to require `%s'" feature)))))

  ;; FIXME: enclose macro defs in the *user-module*, this is different
  ;; to with interpreted code

  (defun note-macro-def (name body)
    (fluid-set! macro-env
	       (cons (cons name
			   (let ((closure (make-closure body name)))
			     (set-closure-structure!
			      closure (find-structure *user-module*))
			     closure))
		     (fluid-ref macro-env))))

  (defun call-with-structure (thunk struct)
    (let-fluids ((current-module (structure-name struct))
		 (current-structure struct)
		 (current-language nil))
      (let-fluids ((open-modules (and (fluid-ref current-structure)
				      (structure-imports
				       (fluid-ref current-structure))))
		   (accessed-modules (and (fluid-ref current-structure)
					  (structure-accessible
					   (fluid-ref current-structure)))))
	(find-language-module)
	(thunk))))

  (defun find-language-module ()
    ;; scan all opened modules for a known language
    (let-escape return
      (for-each
       (lambda (struct)
	 (if (get struct 'compiler-module)
	     (progn
	       (or (intern-structure (get struct 'compiler-module))
		   (compiler-error "unable to load module `%s'"
				   (get struct 'compiler-module)))
	       (fluid-set! current-language struct)
	       (return))))
       (fluid-ref open-modules))
      (fluid-set! current-language 'no-lang)))

  ;; (declare (language LANG))

  (defun declare-language (form)
    (fluid-set! current-language (cadr form)))
  (put 'language 'compiler-decl-fun declare-language)

  ;; (declare (in-module STRUCT))

  (defun declare-in-module (form)
    (fluid-set! current-module (cadr form))
    (fluid-set! current-structure (intern-structure (cadr form))))
  (put 'in-module 'compiler-decl-fun declare-in-module)

  ;; (declare (bootstrap-module STRUCT)

  (defun declare-module-bootstrap (form)
    (let ((module (cadr form)))
      (fluid-set! current-module module)
      (fluid-set! current-structure (intern-structure module))
      ;; FIXME: not entirely correct -- the rep.structures module
      ;; is only available to top-level forms, unless it's opened
      ;; explicitly.
      (fluid-set! open-modules
		  (cons 'rep.structures (fluid-ref open-modules)))))
  (put 'module-bootstrap 'compiler-decl-fun declare-module-bootstrap)

  ;; Module compilers

  (defun compile-anonymous-module (form)
    (compile-structure-def nil (cadr form) (cddr form)))

  (defun compile-define-module (form)
    (compile-structure-def (cadr form) (caddr form) (cdddr form)))

  (defun compile-top-level-module (form)
    (compile-structure-def nil (cadr form) (cddr form) t))

  (defun compile-top-level-define-module (form)
    (compile-structure-def (cadr form) (caddr form) (cdddr form) t))

  (defun compile-structure-def (name sig body #!optional top-level)
    (let
	((opened '(rep.module-system))
	 (accessed '())
	 (config (car body))
	 header)

      (set! body (cdr body))
      (unless (list? (car config))
	(set! config (list config)))
      (for-each (lambda (clause)
		  (case (car clause)
		    ((open)
		     (set! opened (append! (reverse (cdr clause)) opened))
		     (set! header (cons clause header)))

		    ((access)
		     (set! accessed (append! (reverse (cdr clause)) accessed))
		     (set! header (cons clause header)))

		    (t (set! header (cons clause header)))))
		config)
      (set! header (cons '(open rep.module-system) (reverse! header)))

      (let-fluids ((current-structure nil)
		   (current-module name))
	(call-with-module-env
	 (lambda ()
	   (set! body (compile-module-body-1 body))

	   (if top-level
	       (if name
		   `(define-module ,name ,sig ,config ,@body)
		 `(module ,sig ,config ,@body))
	     (compile-form-1 '%make-structure)
	     (compile-form-1 `(%parse-interface ',sig))
	     (if header
		 (progn
		   (compile-constant `(lambda () ,@header))
		   (emit-insn '(enclose)))
	       (compile-constant nil))
	     (if body
		 ;; compile non-top-level structure bodies, so that
		 ;; they can access the active bindings
		 (compile-lambda-constant `(lambda () ,@body))
	       (compile-constant nil))
	     (when name
	       (compile-constant name))
	     (emit-insn `(call ,(if name 4 3)))
	     (decrement-stack (if name 4 3))))
	 opened accessed))))

  (defun compile-module-ref (form)
    (let
	((struct (list-ref form 1))
	 (var (list-ref form 2)))
      (or (memq struct (fluid-ref accessed-modules))
	  (memq struct (fluid-ref open-modules))
	  (compiler-error
	   "referencing non-accessible module `%s'" struct))
      (or (module-exports? struct var)
	  (compiler-error
	   "referencing private variable `%s#%s'" struct var))
      (compile-constant struct)
      (compile-constant var)
      (emit-insn '(structure-ref))
      (decrement-stack)))

  ;; Exported top-level functions

  (defun compile-function (function #!optional name)
    "Compiles the body of the function FUNCTION."
    (interactive "aFunction to compile:")
    (let-fluids ((defuns nil)
		 (defvars nil)
		 (defines nil)
		 (current-fun function)
		 (output-stream nil))
      (let ((body (closure-function function)))
	(unless (bytecode? body)
	  (call-with-structure
	   (lambda ()
	     (set-closure-function! function (compile-lambda body name)))
	   (closure-structure function)))
	function)))

  (defun compile-module (struct)
    "Compiles all function bindings in the module named STRUCT."
    (interactive "SModule name:")
    (let ((struct (intern-structure struct)))
      (when struct
	(structure-for-each (lambda (var value)
			      (when (closure? value)
				(compile-function value var))) struct)))))
