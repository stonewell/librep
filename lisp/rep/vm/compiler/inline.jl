#| inline.jl -- function inlining

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

(define-module rep.vm.compiler.inline

    (export compile-lambda-inline
	    compile-tail-call
	    compile-emitted-lambda)

    (open rep
	  rep.vm.compiler.utils
	  rep.vm.compiler.basic
	  rep.vm.compiler.modules
	  rep.vm.compiler.lap
	  rep.vm.compiler.bindings)

  (define inline-depth (make-fluid 0))		;depth of lambda-inlining
  (defconst max-inline-depth 64)

  (defun push-inline-args (lambda-list args #!optional pushed-args-already tester)
    (let
	((arg-count 0))
      (if (not pushed-args-already)
	  ;; First of all, evaluate each argument onto the stack
	  (while (pair? args)
	    (compile-form-1 (car args))
	    (set! args (cdr args))
	    (set! arg-count (1+ arg-count)))
	;; Args already on stack
	(set! args nil)
	(set! arg-count pushed-args-already))
      ;; Now the interesting bit. The args are on the stack, in
      ;; reverse order. So now we have to scan the lambda-list to
      ;; see what they should be bound to.
      (let
	  ((state 'required)
	   (args-left arg-count)
	   (bind-stack '()))
	(for-each tester (get-lambda-vars lambda-list))
	(while lambda-list
	  (cond
	   ((symbol? lambda-list)
	    (set! bind-stack (cons (cons lambda-list args-left) bind-stack))
	    (set! args-left 0))
	   ((pair? lambda-list)
	    (case (car lambda-list)
	      ((#!optional)
	       (set! state 'optional))
	      ((#!rest)
	       (set! state 'rest))
	      ;; XXX implement keyword params
	      ((#!key)
	       (compiler-error "can't inline `#!key' parameters"))
	      (t (case state
		   ((required)
		    (if (zero? args-left)
			(compiler-error "required arg `%s' missing"
					(car lambda-list))
		      (set! bind-stack (cons (car lambda-list) bind-stack))
		      (set! args-left (1- args-left))))
		   ((optional)
		    (if (zero? args-left)
			(let ((def (cdar lambda-list)))
			  (if def
			      (compile-form-1 (car def))
			    (emit-insn '(push ())))
			  (increment-stack))
		      (set! args-left (1- args-left)))
		    (set! bind-stack (cons (or (caar lambda-list)
					       (car lambda-list)) bind-stack)))
		   ((rest)
		    (set! bind-stack (cons (cons (car lambda-list) args-left)
					   bind-stack))
		    (set! args-left 0)
		    (set! state '*done*)))))))
	  (set! lambda-list (cdr lambda-list)))
	(when (> args-left 0)
	  (compiler-warning 'parameters
	   "%d unused %s to lambda expression"
	   args-left (if (= args-left 1) "parameter" "parameters")))
	(cons args-left bind-stack))))

  (defun pop-inline-args (bind-stack args-left setter)
    ;; Bind all variables
    (while bind-stack
      (if (pair? (car bind-stack))
	  (progn
	    (compile-constant '())
	    (unless (null? (cdr (car bind-stack)))
	      (do ((i 0 (1+ i)))
		  ((= i (cdr (car bind-stack))))
		(emit-insn '(cons))
		(decrement-stack)))
	    (setter (car (car bind-stack))))
	(setter (car bind-stack)))
      (decrement-stack)
      (set! bind-stack (cdr bind-stack)))
    ;; Then pop any args that weren't used.
    (while (> args-left 0)
      (emit-insn '(pop))
      (decrement-stack)
      (set! args-left (1- args-left))))

  ;; This compiles an inline lambda, i.e. FUN is something like
  ;; (lambda (LAMBDA-LIST...) BODY...)
  ;; If PUSHED-ARGS-ALREADY is true it should be a count of the number
  ;; of arguments pushed onto the stack (in reverse order). In this case,
  ;; ARGS is ignored
  (defun compile-lambda-inline (fun args #!optional pushed-args-already
				return-follows name)
    (set! fun (compiler-macroexpand fun))
    (fluid-set! inline-depth (1+ (fluid-ref inline-depth)))
    (when (>= (fluid-ref inline-depth) max-inline-depth)
      (fluid-set! inline-depth 0)
      (compiler-error "can't inline more than %d nested functions"
		      max-inline-depth))
    (let* ((lambda-list (list-ref fun 1))
	   (body (list-tail fun 2))
	   (out (push-inline-args
		 lambda-list args pushed-args-already check-variable-bind))
	   (args-left (car out))
	   (bind-stack (cdr out)))

      ;; skip interactive decl and doc string.
      (while (and (pair? body)
		  (or (string? (car body))
		      (and (pair? (car body))
			   (eq? (car (car body)) 'interactive))))
	(set! body (cdr body)))

      (call-with-frame
       (lambda ()
	 ;; Now we have a list of things to bind to, in the same order
	 ;; as the stack of evaluated arguments. The list has items
	 ;; SYMBOL, (SYMBOL . ARGS-TO-BIND), or (SYMBOL . nil)
	 (emit-push-frame 'variable)
	 (pop-inline-args bind-stack args-left (lambda (x)
						 (create-binding x)
						 (emit-binding x)))
	 (call-with-lambda-record name lambda-list 0
	  (lambda ()
	    (fix-label (lambda-label (current-lambda)))
	    (set-lambda-inlined (current-lambda) t)
	    (compile-body body return-follows)))
	 (emit-pop-frame 'variable)))

      (fluid-set! inline-depth (1- (fluid-ref inline-depth)))))

  (define (pop-between top bottom)
    (or (and (>= top bottom) (>= bottom 0))
	(error "Invalid stack pointers: %d, %d" top bottom))
    (when (/= top bottom)
      (if (= bottom 0)
	  (emit-insn '(pop-all))
	(do ((sp top (1- sp)))
	    ((= sp bottom))
	  (emit-insn '(pop))))))

  (define (unbind-between top bottom)
    (cond ((= bottom -1)
	   (emit-insn '(reset-frames)))
	  ;; if only one frame to remove, prefer pop-frame, as it
	  ;; may get removed entirely by delete-binding-insns.
	  ((and (= bottom 0) (/= top 1))
	   (unless (<= top bottom)
	     (emit-insn '(pop-frames))))
	  (t (do ((bp (1- top) (1- bp)))
		 ((< bp bottom))
	       ;; stamp with frame ID for delete-binding-insns
	       (emit-insn `(pop-frame ,bp))))))

  (defun compile-tail-call (lambda-record args)
    (let* ((out (push-inline-args (lambda-args lambda-record)
				  args nil check-variable-ref))
	   (args-left (car out))
	   (bind-stack (cdr out)))
      (call-with-frame
       (lambda ()
	 (if (let-escape done
	       (for-each (lambda (var)
			   (when (binding-captured? var)
			     (done t)))
			 (get-lambda-vars (lambda-args lambda-record)))
	       nil)
	     ;; some of the parameters bindings have been captured,
	     ;; create new bindings for all of them.
	     (progn
	       (unbind-between (fluid-ref current-b-stack)
			       ;; the 1- is so that the frame of
			       ;; the function itself is also removed
			       (1- (lambda-bp lambda-record)))
	       (emit-insn '(push-frame))
	       (pop-inline-args bind-stack args-left emit-binding))
	   ;; none of the bindings are captured, so just modify them
	   (pop-inline-args bind-stack args-left emit-varset)
	   (unbind-between (fluid-ref current-b-stack)
			   (lambda-bp lambda-record)))
	 ;; force the stack pointer to what it should be
	 (pop-between (fluid-ref current-stack) (lambda-sp lambda-record))
	 (emit-insn `(jmp ,(lambda-label lambda-record)))))))

  (defun compile-emitted-lambda (lambda-record args)
    (pop-between (fluid-ref current-stack) (lambda-sp lambda-record))
    ((lambda-emitter lambda-record) args
     ;; pass in a thunk to unbind back to where the lambda was defined,
     ;; emitting code may need to reference variables before unbinding.
     (lambda ()
       (unbind-between (fluid-ref current-b-stack)
		       (lambda-bp lambda-record))))))
