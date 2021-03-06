(defpackage :cl-lua-test.lexer
  (:use :cl :cl-lua.lexer :cl-lua.token :cl-lua.filepos)
  (:export :test))
(in-package :cl-lua-test.lexer)

(defun make-lines (&rest lines)
  (format nil "~{~a~%~}" lines))

(defun is (string &rest tokens)
  (loop
    :for token1 :in (lex-from-string string)
    :for token2 :in tokens
    :do (prove:subtest "token test"
          (prove:is (token-value token1) (token-value token2) :test #'equalp)
          (prove:is (token-tag token1) (token-tag token2))
          (prove:is (token-linum token1) (token-linum token2)))))

(defun skip-space-and-comment-test ()
  (is (make-lines ""
		    "    "
		    "--coment"
		    "--[==[long comment"
		    "  "
		    "aaaaaaaaaaa"
		    "--]==]"
		    "--[=[   ]=]"
		    "    --[===["
		    "           ---]===]"
		    ""
		    "   +")
      (make-token "+" :tag "+" :filepos (make-filepos nil 12)))
  (prove:is-error (lex-from-string "--[[

")
                  cl-lua.error:unfinished-long-comment-error)
  )

(defun operators-test ()
  (dolist (op '("..." "<<" ">>" "//" "==" "~=" "<=" ">=" "::" ".." "+" "-" "*" "/" "%" "^" "#"
                "&" "~" "|" "<" ">" "=" "(" ")" "{" "}" "[" "]" ";" ":" "," "."))
    (prove:is (if (tag-member op *operator-tags*)
                  t
                  nil)
              t))
  (apply #'is
         (format nil "~{~a ~}" *operator-tags*)
         (mapcar #'(lambda (op)
                     (make-token op :tag op :filepos (make-filepos nil 1)))
                 *operator-tags*)))

(defun word-test ()
  (apply #'is
	 (format nil "~{~a ~}" *keyword-tags*)
	 (mapcar #'(lambda (word)
		     (make-token word :tag word :filepos (make-filepos nil 1)))
		 *keyword-tags*))
  (let ((names (list "abc" "ABC" "aBc" "Abc" "_xyz" "_10" "_d10" "a10")))
    (apply #'is
	   (apply #'make-lines names)
	   (loop :for name :in names
		 :for linum :from 1
		 :collect (make-token name :tag "word" :filepos (make-filepos nil linum))))))

(defun string-test ()
  (is (format nil "~{~a~^ ~}"
              (list "'abc'"
                    (MAKE-LINES "" "" "'abc'")
                    "'\\a\\b\\f\\n\\r\\t\\v\\\\\\\"\\''"
                    (MAKE-LINES "'foo\\z bar'")
                    (MAKE-LINES "'\\z bar'")
                    (MAKE-LINES "'\\zbar'")
                    "\"\\aa\\a\""
                    "'\\x61\\x62\\x63\\x5F\\x5f'"
                    "'\\x611'"
                    "'1\\x611'"
                    "'\\061\\062\\063'"
                    "'foo\\061\\062\\063bar'"
                    "'\\u{3042}\\u{3043}\\u{3044}'"
                    "'あいうえお'"))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "abc") :TAG "string" :filepos (make-filepos nil 1))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "abc") :TAG "string" :filepos (make-filepos nil 3))
      (MAKE-TOKEN
       (cl-lua.lua-object:string-to-lua-string
        (COERCE
         (LIST #\Bel #\Backspace #\Page #\Newline #\Return #\Tab #\Vt #\\ #\" #\')
         'STRING))
       :TAG "string" :filepos (make-filepos nil 4))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "foobar") :TAG "string" :filepos (make-filepos nil 4))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "bar") :TAG "string" :filepos (make-filepos nil 5))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "bar") :TAG "string" :filepos (make-filepos nil 6))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string (COERCE (LIST #\Bel #\a #\Bel) 'STRING))
                  :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "abc__") :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "a1") :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "1a1") :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "=>?") :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN (cl-lua.lua-object:string-to-lua-string "foo=>?bar") :TAG "string" :filepos (make-filepos nil 7))
      (MAKE-TOKEN
       (cl-lua.lua-object:string-to-lua-string (MAP 'STRING #'CODE-CHAR (VECTOR 12354 12355 12356)))
       :TAG "string" :filepos (make-filepos nil 7))
      (make-token (cl-lua.lua-object:string-to-lua-string "あいうえお") :tag "string" :filepos (make-filepos nil 7)))
  (is (make-lines "'foo\\" "bar'")
      (make-token (cl-lua.lua-object:string-to-lua-string (concatenate 'string
                                                       "foo"
                                                       (string #\newline)
                                                       "bar"))
                  :tag "string" :filepos (make-filepos nil 1))))

(defun long-string-test ()
  (is "[[abcd]]"
      (make-token (cl-lua.lua-object:string-to-lua-string "abcd") :tag "string" :filepos (make-filepos nil 1)))
  (is (make-lines ""
                  ""
                  "[["
                  "abc"
                  "xyz]]"
                  ""
                  "[[x]]"
                  "[===["
                  "abcdefg"
                  "foooooooo"
                  "]==]"
                  "]====]"
                  ""
                  "]===]")
      (make-token (cl-lua.lua-object:string-to-lua-string "abc
xyz") :tag "string" :filepos (make-filepos nil 3))
      (make-token (cl-lua.lua-object:string-to-lua-string "x") :tag "string" :filepos (make-filepos nil 7))
      (make-token (cl-lua.lua-object:octets-to-lua-string (coerce (map 'vector #'char-code (make-lines "abcdefg" "foooooooo" "]==]" "]====]" "")) 'cl-lua.lua-object:octets))
                  :tag "string"
                  :filepos (make-filepos nil 8))))

(defun digit-number-test ()
  (is (format nil "~{~a~^ ~}"
              '("123"
                ".1"
                ".123"
                "12."
                "123.456"
                "10e2"
                "2E10"
                "1.2e3"
                "1.2e10"
                "1.12e10"
                "314.16e-2"
                "314.16e+2"))
      (make-token 123 :tag "number" :filepos (make-filepos nil 1))
      (make-token 0.1 :tag "number" :filepos (make-filepos nil 1))
      (make-token 0.123 :tag "number" :filepos (make-filepos nil 1))
      (make-token 12.0 :tag "number" :filepos (make-filepos nil 1))
      (make-token 123.456 :tag "number" :filepos (make-filepos nil 1))
      (make-token 10e2 :tag "number" :filepos (make-filepos nil 1))
      (make-token 2e10 :tag "number" :filepos (make-filepos nil 1))
      (make-token 1.2e3 :tag "number" :filepos (make-filepos nil 1))
      (make-token 1.2e10 :tag "number" :filepos (make-filepos nil 1))
      (make-token 1.12e10 :tag "number" :filepos (make-filepos nil 1))
      (make-token 314.16e-2 :tag "number" :filepos (make-filepos nil 1))
      (make-token 314.16e+2 :tag "number" :filepos (make-filepos nil 1))))

(defun hex-number-test ()
  (prove:is-error (lex-from-string "0x") cl-lua.error:lexer-error)
  (is "0xaf1 0x1a.f1 0x.abc 0x0.1E 0xA23p-4 0X1.921FB54442D18P+1"
      (make-token #xaf1 :tag "number" :filepos (make-filepos nil 1))
      (make-token 26.941406 :tag "number" :filepos (make-filepos nil 1))
      (make-token 0.67089844 :tag "number" :filepos (make-filepos nil 1))
      (make-token 0.1171875 :tag "number" :filepos (make-filepos nil 1))
      (make-token 162.1875 :tag "number" :filepos (make-filepos nil 1))
      (make-token 3.1415925 :tag "number" :filepos (make-filepos nil 1))))

(defun test ()
  (prove:plan nil)
  (skip-space-and-comment-test)
  (operators-test)
  (word-test)
  (string-test)
  (long-string-test)
  (digit-number-test)
  (hex-number-test)
  (prove:finalize))
