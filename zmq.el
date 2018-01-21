;;; zmq.el --- ZMQ bindings for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2018 Nathaniel Nicandro

;; Author: Nathaniel Nicandro <nathanielnicandro@gmail.com>
;; Created: 05 Jan 2018
;; Version: 0.9.0
;; Keywords: zmq distributed messaging
;; X-URL: https://github.com/dzop/emacs-zmq

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;;

;;; Code:

(defgroup zmq nil
  "ZMQ bindings for Emacs"
  :group 'communication)

(require 'cl-lib)
(require 'zmq-ffi)
(require 'zmq-constants)
(when (zmq-has "draft")
  (require 'zmq-draft))

(defun zmq--indent (nspecial pos state)
  (let ((here (point))
        (nargs 0)
        (col nil))
    (goto-char (1+ (nth 1 state)))
    (setq col (1- (current-column)))
    (forward-sexp)
    (catch 'parsed-enough
      (while (< (point) (nth 2 state))
        (forward-sexp)
        (setq nargs (1+ nargs))
        (when (>= nargs nspecial)
          (throw 'parsed-enough t))))
    (goto-char pos)
    (prog1
        ;; Allow the third argument (and preceding arguments) to indent to 4 if
        ;; followed by another argument. Otherwise the third argument indents
        ;; to 2. This is to handle socket options lists which may or may not be
        ;; present.
        (+ (if (and (< nargs nspecial)
                    (re-search-forward "^[ \t]*([ \t]*(" (line-end-position) t))
               4 2)
           col)
      (goto-char here))))

(defun zmq--indent-3 (pos state)
  (zmq--indent 3 pos state))

(defun zmq--indent-4 (pos state)
  (zmq--indent 4 pos state))

;;; Convencience macros for contexts, sockets, and pollers

(defvar zmq-current-context nil
  "The context set by `zmq-current-context'.")

(defmacro with-zmq-context (&rest body)
  "Wrap BODY with a new `zmq-context' that is terminated when BODY completes.
This is mainly meant to be used in subprocesses. If not in a
subprocess use `zmq-current-context'."
  (declare (indent 0) (debug (symbolp &rest form)))
  ;; use --ctx-- just in case any shenanigans happen with `zmq-current-context'
  ;; while running body.
  `(let* ((--ctx--  (zmq-context))
          (zmq-current-context --ctx--))
     (unwind-protect
         (progn ,@body)
       (zmq-terminate-context --ctx--))))

(defmacro with-zmq-socket (sock type &optional options &rest body)
  "Run a form, binding a socket to SOCK with TYPE.
SOCK is an unquoted symbol used as the name of the `zmq-socket'
that will be created. The socket will have a socket type of TYPE.
Optionally pass socket OPTIONS, where OPTIONS is a list of two
element lists in the sense of `let'. BODY is run with SOCK bound
to a socket with TYPE and OPTIONS set on it. When BODY is
complete the `zmq-LINGER' option is set to 0 and the socket is
closed.

Note that the `zmq-current-context' is used to instantiate SOCK."
  (declare (debug (symbolp form &optional form &rest form))
           (indent zmq--indent-3))
  (let ((sock-options
         (if (and (listp options)
                  ;; Ensure options is a list of bindings (in the sense of let)
                  (null (cl-find-if-not
                         (lambda (x) (and (listp x) (= (length x) 2)))
                         options)))
             (cl-loop
              for (option value) in options
              collect `(zmq-set-option ,sock ,option ,value))
           ;; Otherwise options must be part of body
           (setq body (cons options body))
           nil)))
    `(let ((,sock (zmq-socket (zmq-current-context) ,type)))
       (unwind-protect
           (progn
             ,@sock-options
             ,@body)
         ;; http://zguide.zeromq.org/page:all#Making-a-Clean-Exit
         ;;
         ;; NOTE: Alternatively set zmq-BLOCKY on the context before creating a
         ;; socket
         (zmq-set-option ,sock zmq-LINGER 0)
         (zmq-close ,sock)))))

(defmacro with-zmq-poller (poller &rest body)
  "Create a new `zmq-poller' bound to POLLER and run BODY.
After BODY is complete call `zmq-poller-destroy' on POLLER."
  (declare (indent 1))
  `(let ((,poller
          (if (zmq-has "draft") (zmq-poller)
            (error "ZMQ not built with draft API"))))
     (unwind-protect
         (progn ,@body)
       (zmq-destroy-poller ,poller))))

(defun zmq-current-context ()
  "Return the `zmq-current-context'.
Return the symbol value of `zmq-current-context' if non-nil. In
the case that `zmq-current-context' is nil: create a new
`zmq-context', bind it to `zmq-current-context', and return the
newly created context."
  (when zmq-current-context
    (condition-case nil
        ;; Try to get an option to see if the context is still valid
        (zmq-context-get zmq-current-context zmq-BLOCKY)
      (zmq-EFAULT (setq zmq-current-context nil))))
  (or zmq-current-context
      (setq zmq-current-context (zmq-context))))

(defun zmq-cleanup-on-exit ()
  "Terminate the `zmq-current-context'.
Close all sockets which are still open before terminating."
  (while zmq--live-sockets
    (let ((sock (pop zmq--live-sockets)))
      (zmq-socket-set sock zmq-LINGER 0)
      (zmq-close sock)))
  (when zmq-current-context
    (zmq-terminate-context zmq-current-context)))

(add-hook 'kill-emacs-hook #'zmq-cleanup-on-exit)

;;; Socket functions

(defun zmq-bind-to-random-port (sock addr &optional min-port max-port max-tries)
  "Bind SOCK to ADDR on a random port.

ADDR must be an address string without the port that will be
passed to `zmq-bind' if a port is found. Optional arguments
MIN-PORT (inclusive) and MAX-PORT (exclusive) give a range that
the port number will have if `zmq-bind' succeeds within
MAX-TRIES. MIN-PORT defaults to 49152, MAX-PORT defaults to
65536, and MAX-TRIES defaults to 100. If `zmq-bind' succeeds, the
port that was bound is returned. Otherwise nil is returned."
  (setq min-port (or min-port 49152)
        max-port (or max-port 65536)
        max-tries (or max-tries 100))
  (let (port)
    (catch 'bound
      (dotimes (_i max-tries)
        (setq port (+ (cl-random (- max-port min-port)) min-port))
        (condition-case err
            (progn
              (zmq-bind sock (format "%s:%d" addr port))
              (throw 'bound port))
          ((zmq-EACCES zmq-EADDRINUSE)
           (when (eq (car err) 'zmq-EADDRINUSE)
             (unless (eq system-type 'windows-nt)
               (signal (car err) (cdr err))))))))))

;;; Encoding/decoding messages and socket options

(defun zmq-send-encoded (sock str &optional coding-system flags)
  "Send encoded data on SOCK.
STR is the data to encode using CODING-SYSTEM. CODING-SYSTEM
defaults to utf-8. FLAGS has the same meaning as in `zmq-send'."
  (setq coding-system (or coding-system 'utf-8))
  (zmq-send sock (encode-coding-string str coding-system) flags))

(defun zmq-recv-decoded (sock &optional coding-system flags)
  "Received decoded data on SOCK.
CODING-SYSTEM is the coding system to decode the a message
received on SOCK and defaults to utf-8. FLAGS has the same
meaning as in `zmq-recv'."
  (setq coding-system (or coding-system 'utf-8))
  (decode-coding-string (zmq-recv sock flags) coding-system))

(defun zmq-socket-set-encoded (sock option value &optional coding-system)
  "Set an option of SOCK, encoding its value first.
OPTION is the socket option to set and VALUE is its value. Encode
VALUE using CODING-SYSTEM before setting OPTION. CODING-SYSTEM
defaults to utf-8."
  (setq coding-system (or coding-system 'utf-8))
  (zmq-set-option sock option (encode-coding-string value coding-system)))

(defun zmq-socket-get-decoded (sock option &optional coding-system)
  "Get an option of SOCK, return its decoded value.
OPTION is the socket option to get and CODING-SYSTEM is the
coding system to use for decoding. CODING-SYSTEM defaults to
utf-8."
  (setq coding-system (or coding-system 'utf-8))
  (decode-coding-string (zmq-get-option sock option) coding-system))

;;; Sending/receiving multipart messages

(defun zmq-send-multipart (sock parts &optional flags)
  "Send a multipart message on SOCK.
PARTS is a list of message parts to send on SOCK. FLAGS has the
same meaning as `zmq-send'."
  (setq flags (or flags 0))
  (let ((part (zmq-message))
        (data (car parts)))
    (unwind-protect
        (while data
          (zmq-init-message part data)
          (zmq-send-message part sock (if (not (null (cdr parts)))
                                          (logior flags zmq-SNDMORE)
                                        flags))
          (zmq-socket-get sock zmq-EVENTS)
          (setq parts (cdr parts)
                data (car parts)))
      (zmq-close-message part))))

(defun zmq-recv-multipart (sock &optional flags)
  "Receive a multipart message from SOCK.
FLAGS has the same meaning as in `zmq-recv'."
  (let ((part (zmq-message)) res)
    (unwind-protect
        (catch 'recvd
          (while t
            (zmq-init-message part)
            (zmq-recv-message part sock flags)
            (zmq-socket-get sock zmq-EVENTS)
            (setq res (cons (zmq-message-data part) res))
            (unless (zmq-message-more-p part)
              (throw 'recvd (nreverse res)))))
      (zmq-close-message part))))

;;; Setting/getting options from contexts, sockets, messages

(defun zmq--set-get-option (set object option &optional value)
  (let ((fun (cond
              ((zmq-socket-p object)
               (if set #'zmq-socket-set #'zmq-socket-get))
              ((zmq-context-p object)
               (if set #'zmq-context-set #'zmq-context-get))
              ((zmq-message-p object)
               (if set #'zmq-message-set #'zmq-message-get))
              (t (signal 'wrong-type-argument
                         (list
                          '(zmq-socket-p zmq-context-p zmq-message-p)
                          object))))))
    (if set (funcall fun object option value)
      (funcall fun object option))))

(defun zmq-set-option (object option value)
  "For OBJECT, set OPTION to VALUE.

OBJECT can be a `zmq-socket', `zmq-context', or a `zmq-message'.
The OPTION set should correspond to one of the options available
for that particular object."
  (zmq--set-get-option 'set object option value))

(defun zmq-get-option (object option)
  "For OBJECT, get OPTION's value.

OBJECT can be a `zmq-socket', `zmq-context', or a `zmq-message'.
The OPTION to get should correspond to one of the options
available for that particular object."
  (zmq--set-get-option nil object option))

;;; Subprocesses

(define-error 'zmq-subprocess-error "Error in ZMQ subprocess")

(defun zmq-flush (stream)
  "Flush STREAM.
STREAM can be one of `stdout', `stdin', or `stderr'."
  (set-binary-mode stream t)
  (set-binary-mode stream nil))

(defun zmq-prin1 (sexp)
  "Prints SEXP using `prin1' and flushes `stdout' afterwards."
  (prin1 sexp)
  (zmq-flush 'stdout))

(defun zmq--init-subprocess ()
  (if (not noninteractive) (error "Not a subprocess")
    (let* ((debug-on-event nil)
           (debug-on-signal nil)
           (debug-on-quit nil)
           (debug-on-error nil)
           (coding-system-for-write 'utf-8-unix)
           (sexp (eval (zmq-subprocess-read)))
           (wrap-context (= (length (cadr sexp)) 1)))
      (setq sexp (byte-compile sexp))
      (if wrap-context
          (with-zmq-context
            (funcall sexp (zmq-current-context)))
        (funcall sexp)))))

(defun zmq--subprocess-read-output (output)
  "Return a list of s-expressions read from OUTPUT.
OUTPUT is inserted into the `current-buffer' and read for
s-expressions beginning at `point-min' until the first incomplete
s-expression or until all s-expressions have been `read' OUTPUT. After
reading, the contents of the `current-buffer' from `point-min' up
to the last valid s-expression is removed and a list of all the
valid s-expressions in OUTPUT is returned.

Note that if OUTPUT contains any expressions that are read as
symbols, i.e. contains raw text not surrounded by quotes, they
will be ignored.

Note that for this function to work properly the same buffer
should be current for subsequent calls."
  (let (last-valid sexp accum)
    (insert output)
    (goto-char (point-min))
    (while (setq sexp (condition-case err
                          (read (current-buffer))
                        (end-of-file nil)
                        (invalid-read-syntax
                         ;; `read' places `point' at the end of the offending
                         ;; expression so remove it from the buffer so that
                         ;; subsequent calls can make progress.
                         (delete-region (or last-valid (point-min)) (point))
                         (signal 'zmq-subprocess-error err))))
      (setq last-valid (point))
      ;; FIXME: Ignores raw text which gets converted to symbols
      (unless (symbolp sexp)
        (setq accum (cons sexp accum))))
    (delete-region (point-min) (or last-valid (point-min)))
    (nreverse accum)))

(defun zmq--subprocess-filter (process output)
  "Create a stream of s-expressions based on PROCESS' OUTPUT.
If PROCESS has a non-nil `:filter' property then it should be a
function with the same meaning as the EVENT-FILTER argument in
`zmq-start-process'. If the `:filter' function is present, then
it will be called for each s-expression in OUTPUT where output is
converted into a list of s-expressions using
`zmq--subprocess-read-output'.

As a special case, if any of the s-expressions is a list with the
`car' being the symbol error, a `zmq-subprocess-error' is
signaled using the `cdr' of the list for the error data."
  (with-current-buffer (process-buffer process)
    (let ((filter (process-get process :filter)))
      (when filter
        (let ((stream (let ((inhibit-read-only t))
                        (zmq--subprocess-read-output output))))
          (cl-loop
           for event in stream
           if (and (listp event) (eq (car event) 'error)) do
           ;; TODO: Better way to handle this
           (signal 'zmq-subprocess-error (cdr event))
           else do (funcall filter event)))))))

(defun zmq--subprocess-sentinel (process event)
  (let ((sentinel (process-get process :sentinel)))
    (when sentinel
      (funcall sentinel process event)))
  (when (and (process-get process :owns-buffer)
             (cl-loop
              for type in '("exited" "failed" "finished" "killed" "deleted")
              thereis (string-prefix-p type event)))
    (kill-buffer (process-buffer process))))

;; Adapted from `async--insert-sexp' in the `async' package :)
(defun zmq-subprocess-send (process sexp)
  "Send an s-expression to PROCESS' STDIN.
PROCESS should be an Emacs subprocess and which should decode the
SEXP sent using `zmq-subprocess-read'.

The SEXP is first encoded with the `utf-8-unix' coding system and
then encoded using Base 64 encoding before being sent to the
subprocess."
  (declare (indent 1))
  (let ((print-circle t)
        (print-escape-nonascii t)
        print-level print-length)
    (with-temp-buffer
      (prin1 sexp (current-buffer))
      (encode-coding-region (point-min) (point-max) 'utf-8-unix)
      (base64-encode-region (point-min) (point-max) t)
      (goto-char (point-min)) (insert ?\")
      (goto-char (point-max)) (insert ?\" ?\n)
      (process-send-region process (point-min) (point-max)))))

(defun zmq-subprocess-read ()
  "Read a single s-expression from STDIN.
This does the decoding of the encoding described in
`zmq-subprocess-send' and returns the s-expression. This is only
meant to be called from an Emacs subprocess."
  (if (not noninteractive) (error "Not in a subprocess")
    (read (decode-coding-string
           (base64-decode-string (read-minibuffer ""))
           'utf-8-unix))))

(defsubst zmq-set-subprocess-filter (process event-filter)
  "Set the event filter function for PROCESS.
EVENT-FILTER has the same meaning as in `zmq-start-process'."
  (process-put process :filter event-filter))

(defsubst zmq-set-subprocess-sentinel (process sentinel)
  "Set the sentinel function for PROCESS.
SENTINEL has the same meaning as in `zmq-start-process'."
  (process-put process :sentinel sentinel))

(defun zmq-start-process (sexp &optional event-filter sentinel buffer)
  "Start an Emacs subprocess initializing it with SEXP.
SEXP is either a lambda form or a function symbol. In both cases
the function can either take 0 or 1 arguments. If SEXP takes 1
argument, then the function will be wrapped with a call to
`with-zmq-context' and the context passed as the argument of the
function. EVENT-FILTER has a similar meaning to process filters
except raw text sent from the process is ignored and EVENT-FILER
will only receive complete s-expressions which are emitted from
the process. SENTINEL has the same meaning as in `make-process'.

If BUFFER is non-nil it is the initial buffer that will be set as
the `process-buffer' of the process. After this function is
called, the buffer should not be used for any other purpose since
it will be used to store intermediate output from the subprocess
that will eventually be read and sent to EVENT-FILTER. If BUFFER
is nil, a new buffer is generated. Note that in the case that
BUFFER is nil, the generated buffer will be killed upon process
exit. If BUFFER is non-nil, no cleanup of BUFFER is performed on
process exit."
  (cond
   ((functionp sexp)
    (unless (listp sexp)
      (setq sexp (symbol-function sexp))))
   (t (error "Can only send functions to processes")))
  (unless (member (length (cadr sexp)) '(0 1))
    (error "Invalid function to send to process, can only have 0 or 1 arguments"))
  (let* ((process-connection-type nil)
         (process (make-process
                   :name "zmq"
                   :buffer (or buffer (generate-new-buffer " *zmq*"))
                   :connection-type 'pipe
                   :coding-system 'no-conversion
                   :filter #'zmq--subprocess-filter
                   :sentinel #'zmq--subprocess-sentinel
                   :command (list
                             (file-truename
                              (expand-file-name invocation-name
                                                invocation-directory))
                             "-Q" "-batch"
                             "-L" (file-name-directory (locate-library "ffi"))
                             "-L" (file-name-directory (locate-library "zmq"))
                             "-l" (locate-library "zmq")
                             "-f" "zmq--init-subprocess"))))
    (process-put process :filter event-filter)
    (process-put process :sentinel sentinel)
    (process-put process :owns-buffer (null buffer))
    (with-current-buffer (process-buffer process)
      (erase-buffer)
      (special-mode))
    (zmq-subprocess-send process (macroexpand-all sexp))
    process))

(provide 'zmq)

;;; zmq.el ends here
