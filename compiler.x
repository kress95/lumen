;; -*- mode: lisp -*-

(set operators
  (table 'common (table "+" "+" "-" "-" "*" "*" "/" "/" "<" "<"
			">" ">" "=" "==" "<=" "<=" ">=" ">=")
	 'js (table "and" "&&" "or" "||" "cat" "+")
	 'lua (table "and" " and " "or" " or " "cat" "..")))

(defun get-op (op)
  (or (get (get operators 'common) op)
      (get (get operators current-target) op)))

(defun call? (type form)
  (if (not (list? form)) false
      (not (atom? (at form 0))) false
      (= type 'operator) (not (= (get-op (at form 0)) nil))
      (= type 'special) (not (= (get special (at form 0)) nil))
      (= type 'macro) (not (= (get macros (at form 0)) nil))
    false))

(defun symbol-macro? (form)
  (not (= (get symbol-macros form) nil)))

(defun quoting? (depth) (number? depth))
(defun quasiquoting? (depth) (and (quoting? depth) (> depth 0)))
(defun can-unquote? (depth) (and (quoting? depth) (= depth 1)))

(defun macroexpand (form)
  (if ;; expand symbol macro
      (symbol-macro? form) (macroexpand (get symbol-macros form))
      ;; atom
      (atom? form) form
      ;; quote
      (= (at form 0) 'quote) form
      ;; expand macro
      (call? 'macro form)
      (macroexpand (apply (get macros (at form 0)) (sub form 1)))
    ;; list
    (map macroexpand form)))

(defun quasiexpand (form depth)
  (if ;; quasiquoting atom
      (and (atom? form)
	   (quasiquoting? depth))
      (list 'quote form)
      ;; atom
      (atom? form) form
      ;; quote
      (and (not (quasiquoting? depth))
	   (= (at form 0) 'quote))
      (list 'quote (at form 1))
      ;; unquote
      (and (can-unquote? depth)
	   (= (at form 0) 'unquote))
      (quasiexpand (at form 1))
      ;; decrease quasiquoting depth
      (and (quasiquoting? depth)
	   (not (can-unquote? depth))
	   (or (= (at form 0) 'unquote)
	       (= (at form 0) 'unquote-splicing)))
      (quasiquote-unquote form depth)
      ;; increase quasiquoting depth
      (and (quasiquoting? depth)
	   (= (at form 0) 'quasiquote))
      (quasiquote-list form (+ depth 1))
      ;; begin quasiquoting
      (= (at form 0) 'quasiquote)
      (quasiexpand (at form 1) 1)
      ;; quasiquoting list, possible splicing
      (quasiquoting? depth)
      (quasiquote-list form depth)
    ;; list
    (map (lambda (x) (quasiexpand x depth)) form)))

(defun quasiquote-unquote (form depth)
  (list 'list
	(list 'quote (at form 0))
	(quasiexpand (at form 1) (- depth 1))))

(defun quasiquote-list (form depth)
  (do (local xs (list '(list)))
      ;; collect sibling lists
      (across (form x)
	(if (and (list? x)
		 (can-unquote? depth)
		 (= (at x 0) 'unquote-splicing))
	    (do (push xs (quasiexpand (at x 1)))
		(push xs '(list)))
	  (push (last xs) (quasiexpand x depth))))
      (if (= (length xs) 1) ; no splicing
	  (at xs 0)
	;; join all
	(reduce (lambda (a b) (list 'join a b))
		;; remove empty lists
		(filter
		 (lambda (x)
		   (or (= (length x) 0)
		       (not (and (= (length x) 1)
				 (= (at x 0) 'list)))))
		 xs)))))

(defun compile-args (forms compile?)
  (local str "(")
  (across (forms x i)
    (local x1 (if compile? (compile x) (identifier x)))
    (set str (cat str x1))
    (if (< i (- (length forms) 1)) (set str (cat str ","))))
  (cat str ")"))

(defun compile-body (forms tail?)
  (local str "")
  (across (forms x i)
    (local t? (and tail? (= i (- (length forms) 1))))
    (set str (cat str (compile x true t?))))
  str)

(defun identifier (id)
  (local id2 "")
  (local i 0)
  (while (< i (length id))
    (local c (char id i))
    (if (= c "-") (set c "_"))
    (set id2 (cat id2 c))
    (set i (+ i 1)))
  (local last (- (length id) 1))
  (if (= (char id last) "?")
      (do (local name (sub id2 0 last))
	  (set id2 (cat "is_" name))))
  id2)

(defun compile-atom (form)
  (if (= form "nil")
      (if (= current-target 'js) "undefined" "nil")
      (and (string? form) (not (string-literal? form)))
      (identifier form)
    (to-string form)))

(defun compile-call (form)
  (if (= (length form) 0)
      (compile-list form) ; ()
    (do (local fn (at form 0))
	(local fn1 (compile fn))
	(local args (compile-args (sub form 1) true))
	(if (list? fn) (cat "(" fn1 ")" args)
	  (string? fn) (cat fn1 args)
	  (error "Invalid function call")))))

(defun compile-operator ((op args...))
  (local str "(")
  (local op1 (get-op op))
  (across (args arg i)
    (if (and (= op1 '-) (= (length args) 1))
	(set str (cat str op1 (compile arg)))
      (do (set str (cat str (compile arg)))
	  (if (< i (- (length args) 1)) (set str (cat str op1))))))
  (cat str ")"))

(defun compile-do (forms tail?)
  (compile-body forms tail?))

(defun compile-set (form)
  (if (< (length form) 2)
      (error "Missing right-hand side in assignment"))
  (local lh (compile (at form 0)))
  (local rh (compile (at form 1)))
  (cat lh "=" rh))

(defun compile-branch (condition body first? last? tail?)
  (local cond1 (compile condition))
  (local body1 (compile body true tail?))
  (local tr (if (and last? (= current-target 'lua)) " end " ""))
  (if (and first? (= current-target 'js))
      (cat "if(" cond1 "){" body1 "}")
      first?
      (cat "if " cond1 " then " body1 tr)
      (and (= condition nil) (= current-target 'js))
      (cat "else{" body1 "}")
      (= condition nil)
      (cat " else " body1 " end ")
      (= current-target 'js)
      (cat "else if(" cond1 "){" body1 "}")
    (cat " elseif " cond1 " then " body1 tr)))

(defun compile-if (form tail?)
  (local str "")
  (across (form condition i)
    (local last? (>= i (- (length form) 2)))
    (local else? (= i (- (length form) 1)))
    (local first? (= i 0))
    (local body (at form (+ i 1)))
    (if else?
	(do (set body condition)
	    (set condition nil)))
    (set i (+ i 1))
    (set str (cat str (compile-branch condition body first? last? tail?))))
  str)

(defun bind-arguments (args body)
  (local args1 ())
  (across (args arg)
    (if (vararg? arg)
	(do (local v (sub arg 0 (- (length arg) 3)))
	    (local expr
	      (if (= current-target 'js)
		  `(Array.prototype.slice.call arguments ,(length args1))
		(do (push args1 '...) '(list ...))))
	    (set body `((local ,v ,expr) ,@body))
	    break) ; no more args
        (list? arg)
	(do (local v (make-id))
	    (push args1 v)
	    (set body `((bind ,arg ,v) ,@body)))
      (push args1 arg)))
  (list args1 body))

(defun compile-defun ((name args body...))
  (local id (identifier name))
  (compile-function args body id))

(defun compile-lambda ((args body...))
  (compile-function args body))

(defun compile-function (args body name)
  (set name (or name ""))
  (local expanded (bind-arguments args body))
  (local args1 (compile-args (at expanded 0)))
  (local body1 (compile-body (at expanded 1) true))
  (if (= current-target 'js)
      (cat "function " name args1 "{" body1 "}")
    (cat "function " name args1 body1 " end ")))

(defun compile-get ((object key))
  (local o (compile object))
  (local k (compile key))
  (if (and (= current-target 'lua)
	   (= (char o 0) "{"))
      (set o (cat "(" o ")")))
  (cat o "[" k "]"))

(defun compile-dot ((object key))
  (local o (compile object))
  (local id (identifier key))
  (cat o "." id))

(defun compile-not ((expr))
  (local e (compile expr))
  (local open (if (= current-target 'js) "!(" "(not "))
  (cat open e ")"))

(defun compile-return (form)
  (compile-call `(return ,@form)))

(defun compile-local ((name value))
  (local id (identifier name))
  (local keyword (if (= current-target 'js) "var " "local "))
  (if (= value nil)
      (cat keyword id)
    (do (local v (compile value))
	(cat keyword id "=" v))))

(defun compile-while (form)
  (local condition (compile (at form 0)))
  (local body (compile-body (sub form 1)))
  (if (= current-target 'js)
      (cat "while(" condition "){" body "}")
    (cat "while " condition " do " body " end ")))

(defun compile-list (forms depth)
  (local open (if (= current-target 'lua) "{" "["))
  (local close (if (= current-target 'lua) "}" "]"))
  (local str "")
  (across (forms x i)
    (local x1 (if (quoting? depth) (quote-form x) (compile x)))
    (set str (cat str x1))
    (if (< i (- (length forms) 1)) (set str (cat str ","))))
  (cat open str close))

(defun compile-table (forms)
  (local sep (if (= current-target 'lua) "=" ":"))
  (local str "{")
  (local i 0)
  (while (< i (- (length forms) 1))
    (local k (compile (at forms i)))
    (local v (compile (at forms (+ i 1))))
    (if (and (= current-target 'lua) (string-literal? k))
	(set k (cat "[" k "]")))
    (set str (cat str k sep v))
    (if (< i (- (length forms) 2)) (set str (cat str ",")))
    (set i (+ i 2)))
  (cat str "}"))

(defun compile-each (((t k v) body...))
  (local t1 (compile t))
  (if (= current-target 'lua)
      (do (local body1 (compile-body body))
	  (cat "for " k "," v " in pairs(" t1 ") do " body1 " end"))
    (do (local body1 (compile-body `((set ,v (get ,t ,k)) ,@body)))
	(cat "for(" k " in " t1 "){" body1 "}"))))

(defun quote-form (form)
  (if (atom? form)
      (if (string-literal? form)
	  (do (local str (sub form 1 (- (length form) 1)))
	      (cat "\"\\\"" str "\\\"\""))
	(string? form) (cat "\"" form "\"")
	(to-string form))
    (compile-list form 0)))

(defun compile-quote ((form))
  (quote-form form))

(defun compile-defmacro ((name args body...))
  (local lambda `(lambda ,args ,@body))
  (local register `(set (get macros ',name) ,lambda))
  (eval (compile-for-target (current-language) register true))
  "")

(defmacro define-symbol-macro (name expansion)
  (set (get symbol-macros name) expansion)
  nil)

(defun compile-macrolet ((macros body...) tail?)
  (across (macros macro)
    (compile-defmacro macro))
  (local body1 (compile `(do ,@body) nil tail?))
  (across (macros macro)
    (set (get macros (at macro 0)) nil))
  body1)

(defun compile-symbol-macrolet ((expansions body...) tail?)
  (across (expansions expansion)
    (set (get symbol-macros (at expansion 0)) (at expansion 1)))
  (local body1 (compile `(do ,@body) nil tail?))
  (across (expansions expansion)
    (set (get symbol-macros (at expansion 0)) nil))
  body1)

(defun compile-special (form stmt? tail?)
  (local name (at form 0))
  (local sp (get special name))
  (if (and (not stmt?) (get sp 'stmt?))
      (compile `((lambda () ,form)) false tail?)
    (do (local tr? (and stmt? (not (get sp 'self-tr))))
	(local tr (if tr? ";" ""))
	(local fn (get sp 'compiler))
	(cat (fn (sub form 1) tail?) tr))))

(set special
  (table
   "do" (table 'compiler compile-do 'self-tr true 'stmt? true)
   "if" (table 'compiler compile-if 'self-tr true 'stmt? true)
   "while" (table 'compiler compile-while 'self-tr true 'stmt? true)
   "defun" (table 'compiler compile-defun 'self-tr true 'stmt? true)
   "defmacro" (table 'compiler compile-defmacro 'self-tr true 'stmt? true)
   "macrolet" (table 'compiler compile-macrolet 'self-tr true)
   "symbol-macrolet" (table 'compiler compile-symbol-macrolet 'self-tr true)
   "return" (table 'compiler compile-return 'stmt? true)
   "local" (table 'compiler compile-local 'stmt? true)
   "set" (table 'compiler compile-set 'stmt? true)
   "each" (table 'compiler compile-each 'stmt? true)
   "get" (table 'compiler compile-get)
   "dot" (table 'compiler compile-dot)
   "not" (table 'compiler compile-not)
   "list" (table 'compiler compile-list)
   "table" (table 'compiler compile-table)
   "quote" (table 'compiler compile-quote)
   "lambda" (table 'compiler compile-lambda)))

(defun can-return? (form)
  (if (call? 'macro form) false
      (call? 'special form) (not (get (get special (at form 0)) 'stmt?))
    true))

(defun compile (form stmt? tail?)
  (local tr (if stmt? ";" ""))
  (if (and tail? (can-return? form))
      (set form `(return ,form)))
  (if (= form nil) ""
      (symbol-macro? form) (compile (get symbol-macros form) stmt? tail?)
      (atom? form) (cat (compile-atom form) tr)
      (call? 'operator form)
      (cat (compile-operator form) tr)
      (call? 'special form)
      (compile-special form stmt? tail?)
      (call? 'macro form)
      (do (local fn (get macros (at form 0)))
	  (local form (apply fn (sub form 1)))
	  (compile form stmt? tail?))
    (cat (compile-call form) tr)))

(defun compile-file (file)
  (local form)
  (local output "")
  (local s (make-stream (read-file file)))
  (while true
    (set form (read s))
    (if (= form eof) break)
    (set output (cat output (compile (quasiexpand form) true))))
  output)

(defun compile-files (files)
  (local output "")
  (across (files file)
    (set output (cat output (compile-file file))))
  output)

(defun compile-for-target (target args...)
  (local previous-target current-target)
  (set current-target target)
  (local result (apply compile args))
  (set current-target previous-target)
  result)
