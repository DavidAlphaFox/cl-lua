(in-package :cl-user)
(defpackage :cl-lua.lexer
  (:use
   :cl
   :cl-lua.token
   :cl-lua.error
   :cl-lua.util)
  (:export
   :make-lexer
   :lexer-error
   :lex
   :lex-from-string))
(in-package :cl-lua.lexer)

(defstruct (lexer (:constructor make-lexer-internal))
  stream
  line
  linum
  column)

(defun make-lexer (stream)
  (make-lexer-internal :stream stream
		       :line ""
		       :linum 0
		       :column 0))

(defun lexer-error (lexer string &rest args)
  (error 'lexer-error
	 :text (apply #'format nil string args)
	 :linum (lexer-linum lexer)
	 :near (lexer-line lexer)
         :stream (lexer-stream lexer)))

(defun lexer-scan (lexer regex)
  (ppcre:scan regex
	      (lexer-line lexer)
	      :start (lexer-column lexer)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun gen-with-lexer-scans (vars lexer-var regexes body)
    (when regexes
      `(multiple-value-bind (,@vars)
	   (lexer-scan ,lexer-var ,(car regexes))
	 (if (or ,@vars)
             (progn ,@body)
             ,(gen-with-lexer-scans vars lexer-var (cdr regexes) body))))))

(defmacro with-lexer-scans (((&rest vars) (lexer-var &rest regexes))
                            &body body)
  (gen-with-lexer-scans vars lexer-var regexes body))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun gen-with-regex-groups (n vars gstring gstart-groups gend-groups body)
    (if (null vars)
        `(progn ,@body)
        `(let ((,(car vars)
                 (when (aref ,gstart-groups ,n)
                   (subseq ,gstring
                           (aref ,gstart-groups ,n)
                           (aref ,gend-groups ,n)))))
           ,(gen-with-regex-groups (1+ n)
                                   (cdr vars)
                                   gstring
                                   gstart-groups
                                   gend-groups
                                   body)))))

(defmacro with-regex-groups ((vars string start-groups end-groups) &body body)
  (let ((gstring (gensym "STRING"))
        (gstart-groups (gensym "START-GROUPS"))
        (gend-groups (gensym "END-GROUPS")))
    `(let ((,gstring ,string)
           (,gstart-groups ,start-groups)
           (,gend-groups ,end-groups))
       ,(gen-with-regex-groups 0
                               vars
                               gstring
                               gstart-groups
                               gend-groups
                               body))))

(defun next-line (lexer)
  (setf (lexer-line lexer)
	(read-line (lexer-stream lexer)))
  (incf (lexer-linum lexer))
  (setf (lexer-column lexer) 0)
  lexer)

(defun end-column-p (lexer)
  (>= (lexer-column lexer)
      (length (lexer-line lexer))))

(defun ahead-char (lexer)
  (schar (lexer-line lexer) (lexer-column lexer)))

(defun read-line-while-empty (lexer)
  (loop :while (end-column-p lexer)
	:do (next-line lexer)))

(defun space-char-p (c)
  (member c '(#\space #\tab)))

(defun skip-space (lexer)
  (loop :while (not (end-column-p lexer))
	:for c := (ahead-char lexer)
	:if (space-char-p c)
	  :do (incf (lexer-column lexer))
	:else
	  :do (return nil)
	:finally (return t)))

(defun skip-space-lines (lexer)
  (loop
    (read-line-while-empty lexer)
    (unless (skip-space lexer)
      (return t))))

(defun skip-comment (lexer)
  (when (lexer-scan lexer "^--")
    (incf (lexer-column lexer) 2)
    (multiple-value-bind (start end)
	(lexer-scan lexer "^\\[=*\\[")
      (cond (start
	     (setf (lexer-column lexer) end)
	     (scan-long-string lexer (- end start 2) nil))
	    (t
	     (next-line lexer))))
    t))

(defun skip-space-and-comment (lexer)
  (loop
    (skip-space-lines lexer)
    (unless (skip-comment lexer)
      (return t))))

(defun scan-long-string (lexer n fn)
  (loop :with regex := (ppcre:create-scanner
			(concatenate 'string
				     "[^\\\\]?"
				     "\\]"
				     (make-string n :initial-element #\=)
				     "\\]"))
	:do (multiple-value-bind (s e)
		(lexer-scan lexer regex)
	      (when fn
		(funcall fn
			 (if (and (zerop (lexer-column lexer)) (null e))
                             (lexer-line lexer)
                             (subseq (lexer-line lexer)
                                     (lexer-column lexer)
                                     (if e (- e (+ n 2)))))
			 (not s)))
	      (when s
		(setf (lexer-column lexer) e)
		(return)))
	    (next-line lexer)))

(defun try-scan-operator (lexer)
  (multiple-value-bind (s e)
      (lexer-scan lexer
		  `(:sequence
		    :start-anchor
		    (:group
		     (:alternation
		      . #.(sort (copy-list *operator-names*)
				#'>
				:key #'length)))))
    (when s
      (setf (lexer-column lexer) e)
      (let ((str (subseq (lexer-line lexer) s e)))
	(make-token str
		    :tag str
		    :linum (lexer-linum lexer))))))

(defun try-scan-word (lexer)
  (multiple-value-bind (s e)
      (lexer-scan lexer "^[a-zA-Z_][a-zA-Z0-9_]*")
    (when s
      (setf (lexer-column lexer) e)
      (let ((str (subseq (lexer-line lexer) s e)))
	(make-token str
		    :tag (if (tag-member str *keyword-names*)
                             str
                             "word")
		    :linum (lexer-linum lexer))))))

(defun unfinished-string-error (lexer)
  (lexer-error lexer "unfinished string"))

(defun string-hex-error (lexer)
  (lexer-error lexer "hexadecimal digit expected"))

(defun ahead-char-with-eof-handle
    (lexer &optional (handler #'unfinished-string-error))
  (if (end-column-p lexer)
      (funcall handler lexer)
      (ahead-char lexer)))

(defun try-scan-string (lexer)
  (let ((quote-char (ahead-char lexer)))
    (when (or (char= quote-char #\")
	      (char= quote-char #\'))
      (incf (lexer-column lexer))
      (loop :with chars := (make-array 0
				       :fill-pointer 0
				       :adjustable t
				       :element-type '(unsigned-byte 8))
	    :and start-linum := (lexer-linum lexer)
	    :for c := (ahead-char-with-eof-handle lexer)
	    :do (cond
                  ((char= c quote-char)
                   (incf (lexer-column lexer))
                   (return-from try-scan-string
                     (make-token chars
                                 :tag "string"
                                 :linum start-linum)))
                  ((char= c #\\)
                   (incf (lexer-column lexer))
                   (let* ((esc-char (if (end-column-p lexer)
                                        (progn
                                          (next-line lexer)
                                          #\newline)
                                        (prog1 (ahead-char lexer)
                                          (incf (lexer-column lexer)))))
                          (sp-char (case esc-char
                                     (#\a #\Bel)
                                     (#\b #\Backspace)
                                     (#\f #\Page)
                                     (#\n #\Newline)
                                     (#\r #\Return)
                                     (#\t #\Tab)
                                     (#\v #\Vt)
                                     ((#\\ #\' #\" #\newline)
                                      esc-char))))
                     (cond
                       (sp-char
                        (vector-push-extend (char-code sp-char) chars))
                       ((char= esc-char #\z)
                        (cond ((end-column-p lexer)
                               (next-line lexer))
                              ((space-char-p (ahead-char lexer))
                               (incf (lexer-column lexer)))))
                       ((char= esc-char #\x)
                        (let ((hexstr (make-string 2)))
                          (dotimes (i 2)
                            (let ((c (char-upcase
                                      (ahead-char-with-eof-handle lexer))))
                              (cond ((or (char<= #\0 c #\9)
                                         (char<= #\A c #\F))
                                     (setf (aref hexstr i) c)
                                     (incf (lexer-column lexer)))
                                    (t
                                     (string-hex-error lexer)))))
                          (vector-push-extend (parse-integer hexstr :radix 16)
                                              chars)))
                       ((char<= #\0 esc-char #\9)
                        (let ((digit-str (make-string 3)))
                          (setf (aref digit-str 0) esc-char)
                          (dotimes (i 2)
                            (let ((c (ahead-char-with-eof-handle lexer)))
                              (cond ((char<= #\0 c #\9)
                                     (setf (aref digit-str (1+ i)) c)
                                     (incf (lexer-column lexer)))
                                    (t
                                     (return)))))
                          (vector-push-extend
                           (parse-integer digit-str :junk-allowed t)
                           chars)))
                       ((char= esc-char #\u)
                        (multiple-value-bind (start end)
                            (lexer-scan lexer "^{[a-zA-Z0-F]+}")
                          (unless start
                            (lexer-error lexer "invalid escape sequence"))
                          (dolist (code (unicode-to-utf8
                                         (parse-integer
                                          (subseq (lexer-line lexer)
                                                  (1+ start)
                                                  (1- end))
                                          :radix 16)))
                            (vector-push-extend code chars))
                          (setf (lexer-column lexer) end)))
                       (t
                        (lexer-error lexer "invalid escape sequence")))))
                  (t
                   (incf (lexer-column lexer))
                   (let ((code (char-code c)))
                     (if (<= 0 code 255)
                         (vector-push-extend code chars)
                         (loop :for code :across (unicode-to-utf8 code)
                               :do (vector-push-extend code chars))))))))))

(defun try-scan-long-string (lexer)
  (multiple-value-bind (s e)
      (lexer-scan lexer "^\\[=*\\[")
    (when s
      (let ((start-linum (lexer-linum lexer))
	    (vector (make-array 10
				:element-type '(unsigned-byte 8)
				:adjustable t
				:fill-pointer 0)))
	(if (= e (length (lexer-line lexer)))
            (next-line lexer)
            (setf (lexer-column lexer) e))
	(scan-long-string lexer
			  (- e s 2)
			  (lambda (str newline-p)
			    (loop :for c :across str :do
			      (dolist (code (unicode-to-utf8 (char-code c)))
				(vector-push-extend code vector)))
			    (when newline-p
			      (vector-push-extend (char-code #\newline)
                                                  vector))))
	(make-token vector
		    :tag "string"
		    :linum start-linum)))))

(defun try-scan-decimal-number (lexer)
  (with-lexer-scans ((start end)
		     (lexer
		      "^[0-9]+\\.(?:[0-9]+(?:[eE][+\\-]?[0-9]+)?)?"
		      "^\\.[0-9]+(?:[eE][+\\-]?[0-9]+)?"
		      "^[0-9]+[eE][+\\-]?[0-9]+"))
    (when start
      (setf (lexer-column lexer) end)
      (return-from try-scan-decimal-number
	(make-token (float
                     (read-from-string (lexer-line lexer) t nil
                                       :start start
                                       :end end))
		    :tag "number"
		    :linum (lexer-linum lexer)))))
  (multiple-value-bind (start end)
      (lexer-scan lexer "^[0-9]+")
    (when start
      (setf (lexer-column lexer) end)
      (return-from try-scan-decimal-number
	(make-token (parse-integer (subseq (lexer-line lexer) start end))
		    :tag "number"
		    :linum (lexer-linum lexer))))))

(defun make-hex-token (int-str float-str exp-str linum)
  (make-token (if (and int-str (null float-str) (null exp-str))
                  (parse-integer int-str :radix 16)
                  (float (* (+ (if int-str
                                   (parse-integer int-str :radix 16)
                                   0)
                               (if float-str
                                   (/ (parse-integer float-str :radix 16)
                                      (expt 16 (length float-str)))
                                   0))
                            (if exp-str
                                (float (expt 2 (parse-integer exp-str)))
                                1))))
	      :tag "number"
	      :linum linum))

(defun try-scan-hex-number (lexer)
  (multiple-value-bind (start end start-groups end-groups)
      (lexer-scan
       lexer
       "^0[xX]([a-fA-F0-9]+)?(?:\\.([a-fA-F0-9]+))?(?:[pP]([+\\-]?[0-9]+))?")
    (when start
      (with-regex-groups ((int-str float-str exp-str)
			  (lexer-line lexer)
			  start-groups
			  end-groups)
	(when (and (null int-str)
		   (null float-str)
		   (null exp-str))
	  (lexer-error lexer "malformed number"))
	(setf (lexer-column lexer) end)
	(make-hex-token int-str
			float-str
			exp-str
			(lexer-linum lexer))))))

(defun make-eof-token (lexer)
  (make-token nil :tag "eof" :linum (lexer-linum lexer)))

(defun lex (lexer)
  (loop
    (handler-case (skip-space-and-comment lexer)
      (end-of-file () (return-from lex (make-eof-token lexer))))
    (let ((token (or (try-scan-word lexer)
		     (try-scan-string lexer)
		     (try-scan-long-string lexer)
		     (try-scan-hex-number lexer)
		     (try-scan-decimal-number lexer)
		     (try-scan-operator lexer))))
      (when token
	(return-from lex token))
      (incf (lexer-column lexer)))))

(defun lex-from-string (string)
  (with-input-from-string (stream string)
    (loop :with lexer := (make-lexer stream)
	  :for token := (lex lexer)
	  :while (not (eof-token-p token))
	  :collect token)))
