#| utils.jl -- 

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

(define-structure rep.vm.compiler.utils

    (export current-stack max-stack
	    current-b-stack max-b-stack
	    const-env inline-env
	    defuns defvars defines
	    output-stream
	    silence-compiler
	    compiler-error
	    compiler-warning
	    compiler-deprecated
	    remember-function forget-function
	    remember-variable
	    remember-lexical-variable
	    test-variable-ref
	    test-variable-bind
	    test-function-call
	    increment-stack
	    decrement-stack
	    increment-b-stack
	    decrement-b-stack
	    get-lambda-vars
	    compiler-constant?
	    compiler-constant-value
	    constant-function?
	    constant-function-value
	    note-declaration)

    (open rep
	  rep.io.files
	  rep.vm.compiler.modules
	  rep.vm.compiler.bindings
	  rep.vm.compiler.basic
	  rep.vm.bytecodes)

  (define current-stack (make-fluid 0))		;current stack requirement
  (define max-stack (make-fluid 0))		;highest possible stack
  (define current-b-stack (make-fluid 0))	;current binding stack req.
  (define max-b-stack (make-fluid 0))		;highest possible binding stack

  (define const-env (make-fluid '()))		;alist of (NAME . CONST-DEF)
  (define inline-env (make-fluid '()))		;alist of (NAME . FUN-VALUE)
  (define defuns (make-fluid '()))		;alist of (NAME REQ OPT RESTP)
					; for all functions/macros in the file
  (define defvars (make-fluid '()))		;all vars declared at top-level
  (define defines (make-fluid '()))		;all lex. vars. at top-level

  (define output-stream (make-fluid))	;stream for compiler output

  ;; also: shadowing
  (defvar *compiler-warnings* '(unused bindings parameters misc deprecated))
  (define silence-compiler (make-fluid nil))


;;; Message output

  (define last-current-file t)
  (define last-current-fun t)

  (define (ensure-output-stream)
    (when (null? (fluid output-stream))
      (if (or *batch-mode* (not (feature? 'jade)))
	  (fluid-set output-stream (stdout-file))
	(declare (bound open-buffer))
	(fluid-set output-stream (open-buffer "*compilation-output*"))))
    (when (and (feature? 'jade)
	       (progn
		 (declare (bound bufferp goto-buffer goto
				 end-of-buffer current-buffer))
		 (and (bufferp (fluid output-stream))
		      (not (eq? (current-buffer) (fluid output-stream))))))
      (goto-buffer (fluid output-stream))
      (goto (end-of-buffer))))

  (define (abbreviate-file file)
    (let ((c-dd (file-name-as-directory
		 (canonical-file-name *default-directory*)))
	  (c-file (canonical-file-name file)))
      (if (string-prefix? c-file c-dd)
	  (substring c-file (string-length c-dd))
	file)))

  (define (file-prefix #!optional form)
    (unless form
      (setq form (fluid current-form)))
    (let ((origin (and form (lexical-origin form))))
      (cond (origin
	     (format nil "%s:%d: "
		     (abbreviate-file (car origin)) (cdr origin)))
	    ((fluid current-file)
	     (format nil "%s: " (abbreviate-file (fluid current-file))))
	    (t ""))))

  (defun compiler-message (fmt #!key form #!rest args)
    (unless (fluid silence-compiler)
      (ensure-output-stream)
      (unless (and (eq? last-current-fun (fluid current-fun))
		   (eq? last-current-file (fluid current-file)))
	(if (fluid current-fun)
	    (format (fluid output-stream) "%sIn function `%s':\n"
		    (file-prefix form) (fluid current-fun))
	  (format (fluid output-stream) "%sAt top-level:\n"
		  (file-prefix form))))
      (apply format (fluid output-stream)
	     (concat "%s" fmt #\newline) (file-prefix form) args)
      (setq last-current-fun (fluid current-fun))
      (setq last-current-file (fluid current-file))))

  (put 'compile-error 'error-message "Compilation mishap")
  (defun compiler-error (fmt #!key form #!rest data)
    (apply compiler-message fmt #:form form data)
    (signal 'compile-error (list (apply format nil fmt data))))

  (defun compiler-warning (type fmt #!key form #!rest args)
    (when (memq type *compiler-warnings*)
      (apply compiler-message (concat "warning: " fmt) #:form form args)))

  (define deprecated-seen '())

  (defun compiler-deprecated (id fmt #!rest args)
    (unless (memq id deprecated-seen)
      (apply compiler-warning 'deprecated (concat "deprecated - " fmt) args)
      (setq deprecated-seen (cons id deprecated-seen))))


;;; Code to handle warning tests

  ;; Note that there's a function or macro NAME with lambda-list ARGS
  ;; in the current file
  (defun remember-function (name args #!optional body)
    (when body
      (let ((cell (assq name (fluid inline-env))))
	;; a function previously declared inline
	(when (and cell (not (cdr cell)))
	  (set-cdr! cell (list* 'lambda args body)))))
    (if (assq name (fluid defuns))
	(compiler-warning
	 'misc "function or macro `%s' defined more than once" name)
      (let
	  ((count (vector 0 nil nil)) ;required, optional, rest
	   (keys '())
	   (state 0))
	;; Scan the lambda-list for the number of required and optional
	;; arguments, and whether there's a #!rest clause
	(while args
	  (if (symbol? args)
	      ;; (foo . bar)
	      (vector-set! count 2 t)
	    (if (memq (car args) '(&optional &rest #!optional #!key #!rest))
		(case (car args)
		  ((&optional #!optional)
		   (setq state 1)
		   (vector-set! count 1 0))
		  ((#!key)
		   (setq state 'key))
		  ((&rest #!rest)
		   (setq args nil)
		   (vector-set! count 2 t)))
	      (if (number? state)
		  (vector-set! count state (1+ (vector-ref count state)))
		(setq keys (cons (or (caar args) (car args)) keys)))))
	  (setq args (cdr args)))
	(fluid-set defuns (cons (list name (vector-ref count 0)
				      (vector-ref count 1)
				      (vector-ref count 2) keys)
				(fluid defuns))))))

  (defun forget-function (name)
    (let ((cell (assq name (fluid defuns))))
      (fluid-set defuns (delq! cell (fluid defuns)))))

  ;; Similar for variables
  (defun remember-variable (name)
    (cond ((memq name (fluid defines))
	   (compiler-error
	    "variable `%s' was previously declared lexically" name))	;
	  ((memq name (fluid defvars))
	   (compiler-warning 'misc "variable `%s' defined more than once" name))
	  (t
	   (fluid-set defvars (cons name (fluid defvars))))))

  (defun remember-lexical-variable (name)
    (cond ((memq name (fluid defvars))
	   (compiler-error "variable `%s' was previously declared special" name))
	  ((memq name (fluid defines))
	   (compiler-warning
	    'misc "lexical variable `%s' defined more than once" name))
	  (t
	   (fluid-set defines (cons name (fluid defines))))))

  ;; Test that a reference to variable NAME appears valid
  (defun test-variable-ref (name)
    (when (and (symbol? name)
	       (not (keyword? name))
	       (null? (memq name (fluid defvars)))
	       (null? (memq name (fluid defines)))
	       (not (has-local-binding? name))
	       (null? (assq name (fluid defuns)))
	       (not (compiler-bound? name)))
      (compiler-warning
       'bindings "referencing undeclared free variable `%s'" name)))

  ;; Test that binding to variable NAME appears valid
  (defun test-variable-bind (name)
    (cond ((assq name (fluid defuns))
	   (compiler-warning
	    'shadowing "binding to `%s' shadows function" name))
	  ((has-local-binding? name)
	   (compiler-warning
	    'shadowing "binding to `%s' shadows earlier binding" name))
	  ((and (compiler-bound? name)
		(function? (compiler-symbol-value name)))
	   (compiler-warning
	    'shadowing "binding to `%s' shadows pre-defined value" name))))

  ;; Test a call to NAME with NARGS arguments
  ;; XXX functions in comp-fun-bindings aren't type-checked
  ;; XXX this doesn't handle #!key params
  (defun test-function-call (name nargs)
    (when (symbol? name)
      (catch 'return
	(let
	    ((decl (assq name (fluid defuns))))
	  (when (and (null? decl) (or (assq name (fluid inline-env))
				     (compiler-bound? name)))
	    (setq decl (or (cdr (assq name (fluid inline-env)))
			   (compiler-symbol-value name)))
	    (when (or (subr? decl)
		      (and (closure? decl)
			   (eq? (car (closure-function decl)) 'autoload)))
	      (throw 'return))
	    (when (eq? (car decl) 'macro)
	      (setq decl (cdr decl)))
	    (when (closure? decl)
	      (setq decl (closure-function decl)))
	    (unless (bytecode? decl)
	      (remember-function name (list-ref decl 1)))
	    (setq decl (assq name (fluid defuns))))
	  (if (null? decl)
	      (unless (or (has-local-binding? name)
			  (memq name (fluid defvars))
			  (memq name (fluid defines))
			  (locate-variable name))
		(compiler-warning
		 'misc "calling undeclared function `%s'" name))
	    (let
		((required (list-ref decl 1))
		 (optional (list-ref decl 2))
		 (rest (list-ref decl 3))
		 (keys (list-ref decl 4)))
	      (if (< nargs required)
		  (compiler-warning
		   'parameters "%d %s required by `%s'; %d supplied"
		   required (if (= required 1) "argument" "arguments")
		   name nargs)
		(when (and (null? rest) (null? keys)
			   (> nargs (+ required (or optional 0))))
		  (compiler-warning
		   'parameters "too many arguments to `%s' (%d given, %d used)"
		   name nargs (+ required (or optional 0)))))))))))


;;; stack handling

  ;; Increment the current stack size, setting the maximum stack size if
  ;; necessary
  (defmacro increment-stack (#!optional n)
    (list 'when (list '> (list 'fluid-set 'current-stack
			       (if n
				   (list '+ '(fluid current-stack) n)
				 (list '1+ '(fluid current-stack))))
			 '(fluid max-stack))
	  '(fluid-set max-stack (fluid current-stack))))

  ;; Decrement the current stack usage
  (defmacro decrement-stack (#!optional n)
    (list 'fluid-set 'current-stack 
	  (if n
	      (list '- '(fluid current-stack) n)
	    (list '1- '(fluid current-stack)))))

  (defun increment-b-stack ()
    (fluid-set current-b-stack (1+ (fluid current-b-stack)))
    (when (> (fluid current-b-stack) (fluid max-b-stack))
      (fluid-set max-b-stack (fluid current-b-stack))))

  (defun decrement-b-stack ()
    (fluid-set current-b-stack (1- (fluid current-b-stack))))



  ;; Remove all keywords from a lambda list ARGS, returning the list of
  ;; variables that would be bound (in the order they would be bound)
  (defun get-lambda-vars (args)
    (let
	(vars)
      (while args
	(if (symbol? args)
	    (setq vars (cons args vars))
	  (unless (memq (car args) '(#!optional #!key #!rest &optional &rest))
	    (setq vars (cons (or (caar args) (car args)) vars))))
	(setq args (cdr args)))
      (reverse! vars)))


;;; constant forms

;; Return t if FORM is a constant
(defun compiler-constant? (form)
  (cond
   ((pair? form)
    ;; XXX this is wrong, but easy..!
    (eq? (car form) 'quote))
   ((symbol? form)
    (or (keyword? form)
	(assq form (fluid const-env))
	(compiler-binding-immutable? form)))
   ;; Assume self-evaluating
   (t t)))

;; If FORM is a constant, return its value
(defun compiler-constant-value (form)
  (cond
   ((pair? form)
    ;; only quote
    (list-ref form 1))
   ((symbol? form)
    (cond ((keyword? form) form)
	  ((compiler-binding-immutable? form)
	   (compiler-symbol-value form))
	  (t (cdr (assq form (fluid const-env))))))
   (t form)))

(defun constant-function? (form)
  (setq form (compiler-macroexpand form))
  (and (memq (car form) '(lambda function))
       ;; XXX this is broken
       (compiler-binding-from-rep? (car form))))

(defun constant-function-value (form)
  (setq form (compiler-macroexpand form))
  (cond ((eq? (car form) 'lambda)
	 form)
	((eq? (car form) 'function)
	 (list-ref form 1))))


;;; declarations

(defun note-declaration (form)
  (for-each
   (lambda (clause)
     (let ((handler (get (or (car clause) clause) 'compiler-decl-fun)))
       (if handler
	   (handler clause)
	 (compiler-warning 'misc "unknown declaration: `%s'" clause))))
   form))

(defun declare-inline (form)
  (for-each
   (lambda (name)
     (when (symbol? name)
       (unless (assq name (fluid inline-env))
	 (fluid-set inline-env (cons (cons name nil) (fluid inline-env))))))
   (cdr form)))

(put 'inline 'compiler-decl-fun declare-inline)

)
